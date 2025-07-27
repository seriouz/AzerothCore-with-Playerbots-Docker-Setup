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

# yq installieren (wenn nicht vorhanden)
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
fi

azerothcoredir=""
START_PATH=`pwd`

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
        git clone --depth=1 https://github.com/liyunfan1223/mod-playerbots.git --branch=master
        cp mod-playerbots/conf/playerbots.conf.dist mod-playerbots/conf/playerbots.conf
        cd ../..
        azerothcoredir=$(pwd)/azerothcore-wotlk
    else
        echo "Aborting..."
        exit 1
    fi
fi

custom_sql_dir="src/sql"
auth="acore_auth"
world="acore_world"
chars="acore_characters"
ip_address=$(hostname -I | awk '{print $1}')
temp_sql_file="/tmp/temp_custom_sql.sql"
override_file="azerothcore-wotlk/docker-compose.override.yml"

proxy_dir="proxy"
proxy_image="ac-proxy"

volume_entry1="../database:/var/lib/mysql"
volume_entry2="./modules:/azerothcore/modules"

if [ -z "$(yq eval ".services.ac-database.volumes[] | select(. == \"$volume_entry1\")" "$override_file")" ]; then
  yq eval -i ".services.ac-database.volumes += [\"$volume_entry1\"]" "$override_file"
fi

if [ -z "$(yq eval ".services.ac-worldserver.volumes[] | select(. == \"$volume_entry2\")" "$override_file")" ]; then
  yq eval -i ".services.ac-worldserver.volumes += [\"$volume_entry2\"]" "$override_file"
fi

sudo chown -R 1000:1000 azerothcore-wotlk/env/dist/etc azerothcore-wotlk/env/dist/logs

if [ -d "azerothcore-wotlk" ]; then
    echo "Skipping initial docker-compose..."
else
    cd azerothcore-wotlk
    docker compose down
    cd ..

    sudo chown -R 1000:1000 azerothcore-wotlk/env/dist/etc azerothcore-wotlk/env/dist/logs
    docker compose -f azerothcore-wotlk/docker-compose.yml -f azerothcore-wotlk/docker-compose.override.yml up -d --build

    sleep 60
    cd azerothcore-wotlk
    docker compose down
    cd ..
fi

sudo chown -R 1000:1000 wotlk

# Array zur Registrierung der Mods mit SQL
registered_mod_sqls=()

function register_mod_sqls() {
    local mod_name="$1"
    registered_mod_sqls+=("$mod_name")
}

function install_mod() {
    local mod_name=$1
    local repo_url=$2
    local commit_id="${3:-}"
    if [ -d "${mod_name}" ]; then
        echo "📁 ${mod_name} exists. Pulling latest changes..."
        cd "${mod_name}"
        git checkout master
        git pull --no-rebase
        cd ..
    else
        if ask_user "Install ${mod_name}?"; then
            git clone "${repo_url}" "${mod_name}"
        fi
    fi

    if [ -n "$commit_id" ]; then
        echo "📁 ${mod_name} pinned to commit ${commit_id}"
        cd "${mod_name}"
        git checkout $commit_id
        cd ..
    fi
}

function apply_mod_conf() {
    local mod_name="$1"
    local conf_dir="$mod_name/conf"
    echo "Looking for .conf.dist files in $conf_dir (exists: $( [ -d "$conf_dir" ] && echo yes || echo no ))"

    if [ -d "$conf_dir" ]; then
        echo "Copying .conf.dist files for $mod_name"
        while IFS= read -r -d '' conf_file; do
            conf_name="$(basename "$conf_file" .dist)"

            # target_path="$azerothcoredir/env/dist/etc/modules/$conf_name"
            # mkdir -p "$(dirname "$target_path")"
            # cp "$conf_file" "$target_path"
            # echo "→ Copied: $conf_file → $target_path"

            local_conf_path="$(dirname "$conf_file")/$conf_name"
            cp "$conf_file" "$local_conf_path"
            echo "→ Renamed copy: $local_conf_path"

        done < <(find "$conf_dir" -type f -name "*.conf.dist" -print0)
    else
        echo "⚠️  Directory does not exist: $conf_dir"
    fi
}

function apply_mod_sqls() {
    local mod_name="$1"
    local mod_path="azerothcore-wotlk/modules/$mod_name"
    local mod_sql_paths=( "./sql" "./data/sql" )

    pushd "$mod_path" > /dev/null || return

    echo "Applying SQL files for $mod_name"
    for base_path in "${mod_sql_paths[@]}"; do
        [ ! -d "$base_path" ] && continue

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

            if ! mysql -h "$ip_address" -uroot -ppassword "$db" < "$temp_sql_file"; then
                echo "⚠️  SQL import failed for $sql_file, but continuing..."
            fi

        done < <(find "$base_path" -type f -name "*.sql" -print0)
    done

    popd > /dev/null
}

function set_worldserverconf_value() {
    local key="$1"
    local value="$2"
    local conf_path="$START_PATH/conf/worldserver.conf"

    if [ ! -f "$conf_path" ]; then
        echo "⚠️  Config file not found: $conf_path"
        return 1
    fi

    if grep -q -E "^\s*${key}\s*=" "$conf_path"; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|" "$conf_path"
        echo "✅ Set: ${key} = ${value}"
    else
        echo "➕ Adding: ${key} = ${value}"
        echo "${key} = ${value}" >> "$conf_path"
    fi
}

function modify_compose_ports() {
    local compose_file="azerothcore-wotlk/docker-compose.yml"
    local backup_file="${compose_file}.bak"

    echo "🔧 Backup of $compose_file..."
    cp "$compose_file" "$backup_file"

    echo "🔧 Patch ports for proxy..."
    yq eval -i '
      .services.ac-authserver.ports = ["13724:3724"]
    ' "$compose_file"

    yq eval -i '
      .services.ac-worldserver.ports = ["7878:7878","18085:8085"]
    ' "$compose_file"
}

function restore_compose_file() {
    local compose_file="azerothcore-wotlk/docker-compose.yml"
    local backup_file="${compose_file}.bak"

    if [ -f "$backup_file" ]; then
        echo "♻️  Restore $compose_file ..."
        mv "$backup_file" "$compose_file"
    fi
}

function unpause_containers() {
    local containers=("ac-worldserver" "ac-authserver")

    for c in "${containers[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -qw "$c"; then
            status=$(docker inspect -f '{{.State.Paused}}' "$c")
            if [ "$status" = "true" ]; then
                echo "Unpausing container $c..."
                docker unpause "$c"
            fi
        fi
    done

    local c="ac-proxy"
    if docker ps -a --format '{{.Names}}' | grep -qw "$c"; then
        status=$(docker inspect -f '{{.State.Running}}' "$c")
        if [ "$status" = "true" ]; then
            echo "Pausing container $c..."
            docker pause "$c"
        fi
    fi
}

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

# Modulinstallation
if ask_user "Install modules?"; then
    cd azerothcore-wotlk/modules

    install_mod "mod-aoe-loot" "https://github.com/azerothcore/mod-aoe-loot.git"
    apply_mod_conf "mod-aoe-loot"
    # set_worldserverconf_value "Rate.Corpse.Decay.Looted" "0.5"

    install_mod "mod-learnspells" "https://github.com/noisiver/mod-learnspells.git"
    apply_mod_conf "mod-learnspells"
# TODO SET LearnSpells.Gamemasters = 1

    install_mod "mod-congrats-on-level" "https://github.com/azerothcore/mod-congrats-on-level.git"
    apply_mod_conf "mod-congrats-on-level"
    register_mod_sqls "mod-congrats-on-level"
# TODO SETUP rewards

    install_mod "mod-ah-bot" "https://github.com/azerothcore/mod-ah-bot.git" "069773c"
    apply_mod_conf "mod-ah-bot"
    register_mod_sqls "mod-ah-bot"
# TODO SETUP AH BOT

    install_mod "mod-transmog" "https://github.com/azerothcore/mod-transmog.git"
    apply_mod_conf "mod-transmog"
    register_mod_sqls "mod-transmog"
# TODO place transmog NPC in cities

    install_mod "mod-solocraft" "https://github.com/azerothcore/mod-solocraft.git"
    apply_mod_conf "mod-solocraft"
    register_mod_sqls "mod-solocraft"
# TODO Solocraft.conf einstellen für einfache dungeons

    install_mod "mod-eluna" "https://github.com/azerothcore/mod-eluna.git"
# TODO Taschen verschenken beim login

    install_mod "mod-account-mounts" "https://github.com/azerothcore/mod-account-mounts.git"
    apply_mod_conf "mod-account-mounts"

    cd ../..
fi

mkdir -p database

# Nur hinzufügen, wenn NICHT vorhanden
volume_entry3="./lua_scripts:/lua_scripts:ro"
if [ -z "$(yq eval ".services.ac-database.volumes[] | select(. == \"$volume_entry3\")" "$override_file")" ]; then
  yq eval -i ".services.ac-database.volumes += [\"$volume_entry3\"]" "$override_file"
fi

yq eval -i '
  .services.ac-worldserver.environment += {
    "AC_UPDATES_ENABLE_DATABASES", "1",
    "AC_RATE_XP_KILL": "5",
    "AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN": "0",
    "AC_ELUNA_LOAD_SCRIPTS": "1",
    "AC_ELUNA_LUA_SCRIPTS_PATH": "/lua_scripts"
  }
' "$override_file"

yq eval -i '
  .services.ac-worldserver.deploy.resources.limits.cpus = "5.2"
' "$override_file"

sudo chown -R 1000:1000 azerothcore-wotlk/env/dist/etc azerothcore-wotlk/env/dist/logs

modify_compose_ports
unpause_containers
# Main compose with build
docker compose -f azerothcore-wotlk/docker-compose.yml -f azerothcore-wotlk/docker-compose.override.yml up -d --build
restore_compose_file
sudo chown -R 1000:1000 wotlk

docker cp ac-worldserver:/azerothcore/env/dist/etc/worldserver.conf ./conf
set_worldserverconf_value "Ra.Enable" "1"
# TODO Setup PLAYERBOTS IDLE
# Nur hinzufügen, wenn NICHT vorhanden
volume_entry4="../conf/worldserver.conf:/azerothcore/env/dist/etc/worldserver.conf"
if [ -z "$(yq eval ".services.ac-worldserver.volumes[] | select(. == \"$volume_entry4\")" "$override_file")" ]; then
  yq eval -i ".services.ac-worldserver.volumes += [\"$volume_entry4\"]" "$override_file"
fi
# Second compose to apply modifed worldserver.conf
docker compose -f azerothcore-wotlk/docker-compose.yml -f azerothcore-wotlk/docker-compose.override.yml up -d

# Anwenden der registrierten SQLs
for mod in "${registered_mod_sqls[@]}"; do
    echo "▶ Applying registered SQLs for: $mod"
    apply_mod_sqls "$mod"
done

echo "Running final custom SQL imports..."
execute_sql "$auth"
execute_sql "$world"
execute_sql "$chars"

rm -f "$temp_sql_file"

docker restart ac-worldserver

if [ -d "$proxy_dir" ]; then
    echo "🔧 Building $proxy_image container..."
    docker build -t "$proxy_image:latest" "$proxy_dir"
else
    echo "⚠️  Proxy directory $proxy_dir not found - skipping proxy build."
fi

if docker image inspect "$proxy_image" >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -qw "$proxy_image"; then
        echo "▶ Removing existing container $proxy_image..."
        docker unpause "$proxy_image"
        docker rm -f "$proxy_image"
    fi

    echo "▶ Starting $proxy_image container..."
    docker run -d --name $proxy_image \
        --network azerothcore-wotlk_ac-network \
        -p 3724:3724 \
        -p 8085:8085 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v ./$proxy_dir/conf.env:/env/conf.env:ro \
        "$proxy_image:latest"
fi

echo ""
echo "✅ SETUP COMPLETED"
echo ""
echo "1. Run:  docker attach ac-worldserver"
echo "2. Use:  account create NAME PASSWORD"
echo "3. Use:  account set gmlevel NAME 3 -1"
echo "4. Exit with Ctrl+P, Ctrl+Q"
echo "5. In realmlist.wtf: set realmlist $ip_address"
