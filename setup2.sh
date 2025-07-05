#!/bin/bash
set -euo pipefail

function ask_user() {
    read -p "$1 (y/n): " choice
    case "$choice" in
        y|Y ) return 0;;
        * ) return 1;;
    esac
}

# Zeitzone setzen
sed -i "s|^TZ=.*$|TZ=$(cat /etc/timezone)|" src/.env

sudo apt update

azerothcoredir=""

# MariaDB-Client prüfen
if ! command -v mysql &> /dev/null; then
    echo "MySQL client is not installed. Installing..."
    sudo apt install -y mariadb-client
fi

# Docker prüfen
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing..."
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $USER
    echo "Please log out and back in, then rerun setup.sh."
    exit 1
fi

# AzerothCore vorhanden?
if [ -d "azerothcore-wotlk" ]; then
    cd azerothcore-wotlk
    azerothcoredir=$(pwd)
    cd ..

    rm -f azerothcore-wotlk/data/sql/custom/db_world/*.sql
    rm -f azerothcore-wotlk/data/sql/custom/db_characters/*.sql
    rm -f azerothcore-wotlk/data/sql/custom/db_auth/*.sql

    cp src/.env azerothcore-wotlk/
    cp src/*.yml azerothcore-wotlk/
else
    if ask_user "Download and install AzerothCore Playerbots?"; then
        git clone --depth=1 https://github.com/liyunfan1223/azerothcore-wotlk.git --branch=Playerbot
        cp src/.env azerothcore-wotlk/
        cp src/*.yml azerothcore-wotlk/
        cd azerothcore-wotlk/modules
        git clone --depth=1 https://github.com/liyunfan1223/mod-playerbots.git
        cd ../..
        azerothcoredir=$(pwd)/azerothcore-wotlk
    else
        echo "Aborting..."
        exit 1
    fi
fi

# Modulinstallation
if ask_user "Install modules?"; then
    cd azerothcore-wotlk/modules

    function install_mod() {
        local mod_name=$1
        local repo_url=$2
        if [ -d "${mod_name}" ]; then
            echo "${mod_name} exists. Skipping..."
        else
            if ask_user "Install ${mod_name}?"; then
                git clone "${repo_url}"
            fi
        fi
    }

    function apply_mod_sqls_and_conf() {
        local mod_name="$1"
        local mod_sql_paths=( "./sql" "./data/sql" )

        pushd "$mod_name" > /dev/null || return

        echo "Applying SQL files for $mod_name"
        for base_path in "${mod_sql_paths[@]}"; do
            if [ ! -d "$base_path" ]; then continue; fi

            while IFS= read -r -d '' sql_file; do
                path_lower=$(echo "$sql_file" | tr '[:upper:]' '[:lower:]')
                local db=""
                if [[ "$path_lower" == *world* ]]; then
                    db="acore_world"
                elif [[ "$path_lower" == *char* ]]; then
                    db="acore_characters"
                elif [[ "$path_lower" == *auth* ]]; then
                    db="acore_auth"
                else
                    echo "⚠️  Unknown DB for: $sql_file"
                    continue
                fi

                echo "→ Executing on $db: $sql_file"
                temp_sql_file=$(mktemp)
                if [[ "$(basename "$sql_file")" == "update_realmlist.sql" ]]; then
                    sed -e "s/{{IP_ADDRESS}}/$ip_address/g" "$sql_file" > "$temp_sql_file"
                else
                    cp "$sql_file" "$temp_sql_file"
                fi
                mysql -h "$ip_address" -uroot -ppassword "$db" < "$temp_sql_file"
            done < <(find "$base_path" -type f -name "*.sql" -print0)
        done

        echo "Copying .conf.dist files for $mod_name"
        while IFS= read -r -d '' conf_file; do
            conf_name="$(basename "$conf_file" .dist)"
            target_path="$azerothcoredir/env/dist/etc/modules/$conf_name"
            mkdir -p "$(dirname "$target_path")"
            cp "$conf_file" "$target_path"
            echo "→ Copied: $conf_file → $target_path"
        done < <(find "./conf" -type f -name "*.conf.dist" -print0)

        popd > /dev/null
    }

    install_mod "mod-aoe-loot" "https://github.com/azerothcore/mod-aoe-loot.git"
    install_mod "mod-learn-spells" "https://github.com/noisiver/mod-learnspells.git"
    install_mod "mod-fireworks-on-level" "https://github.com/azerothcore/mod-fireworks-on-level.git"
    install_mod "mod-ah-bot" "https://github.com/azerothcore/mod-ah-bot.git"
    apply_mod_sqls_and_conf "mod-ah-bot"
    install_mod "mod-transmog" "https://github.com/azerothcore/mod-transmog.git"
    apply_mod_sqls_and_conf "mod-transmog"
    install_mod "mod-solocraft" "https://github.com/azerothcore/mod-solocraft.git"
    apply_mod_sqls_and_conf "mod-solocraft"
    install_mod "mod-eluna" "https://github.com/azerothcore/mod-eluna.git"
    install_mod "mod-account-mounts" "https://github.com/azerothcore/mod-account-mounts.git"

    cd ../..
fi

sudo chown -R 1000:1000 azerothcore-wotlk/env/dist/etc azerothcore-wotlk/env/dist/logs

docker compose -f azerothcore-wotlk/docker-compose.yml up -d --build

sudo chown -R 1000:1000 wotlk

custom_sql_dir="src/sql"
auth="acore_auth"
world="acore_world"
chars="acore_characters"
ip_address=$(hostname -I | awk '{print $1}')
temp_sql_file="/tmp/temp_custom_sql.sql"

function execute_sql() {
    local db_name=$1
    local sql_files=("$custom_sql_dir/$db_name"/*.sql)
    if [ -e "${sql_files[0]}" ]; then
        for custom_sql_file in "${sql_files[@]}"; do
            echo "Running custom SQL: $custom_sql_file"
            temp_sql_file=$(mktemp)
            if [[ "$(basename "$custom_sql_file")" == "update_realmlist.sql" ]]; then
                sed -e "s/{{IP_ADDRESS}}/$ip_address/g" "$custom_sql_file" > "$temp_sql_file"
            else
                cp "$custom_sql_file" "$temp_sql_file"
            fi
            mysql -h "$ip_address" -uroot -ppassword "$db_name" < "$temp_sql_file"
        done
    else
        echo "No custom SQL in $custom_sql_dir/$db_name"
    fi
}

echo "Running final custom SQL imports..."
execute_sql "$auth"
execute_sql "$world"
execute_sql "$chars"

rm -f "$temp_sql_file"

echo ""
echo "✅ SETUP COMPLETED"
echo ""
echo "1. Run:  docker attach ac-worldserver"
echo "2. Use:  account create NAME PASSWORD"
echo "3. Use:  account set gmlevel NAME 3 -1"
echo "4. Exit with Ctrl+P, Ctrl+Q"
echo "5. In realmlist.wtf: set realmlist $ip_address"
