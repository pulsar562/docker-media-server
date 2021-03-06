#!/bin/bash
if [[ $UID -ne 0 ]]; then
    echo "Must be run as root"
    exit 1;
fi


## Install Prerequisites
function install_docker() {
  dnf -y update
  dnf -y install python-pip
  pip install --upgrade pip
  curl -sL https://get.docker.com > docker.sh
  bash docker.sh
  pip install docker-compose
}


## Define some variables
docker=$(type -p docker)
docker_compose=$(type -p docker-compose)
systemctl=$(type -p systemctl)
firewalld=$(type -p firewalld)

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
app_dir="/usr/local/share/docker/docker-mediaserver"
config_dir="/apps/configs"

yml_file="${script_dir}/docker-compose.yml"
unit_file="${script_dir}/compose-mediaserver.service"
env_file="${script_dir}/ids.env"

declare -a services=(plex plexrequests nzbget sonarr couchpotato plexpy)

## Tests
function tests() {
	
	  tests=(${1} ${2})

	  [[ ! -f ${app_dir}/.setup_run ]] && setup_run=0 || setup_run=1

    if [[ ${setup_run} -eq 0 ]]; then
		  len=${#tests[@]}
		  i=0
		  while [[ $i -lt ${len} ]]; do
        if [[ -z ${tests[${i}]} ]]; then
				  echo "${tests[${i}]} was not found, attempting to install";
          install_docker
				  exit 1;
		    else
			    echo "${tests[${i}]} found";
			    i=$(( i + 1 ))
		    fi
		  done
    
	  else
        echo "Setup Already ran"
        echo "To re-run, delete ${app_dir}/.setup_run"
        exit 0;
    fi

		if [[ ! -z ${3} ]]; then
			has_systemd=1
			echo "OS using Systemd"
		else
			has_systemd=0
		fi
		
    if [[ ! -z ${4} ]]; then
			has_firewalld=1
			echo "OS using Firewalld"
		else
			has_firewalld=0
		fi

}

function setup(){

    #### Create user and group "plex". If already created, set the uid and gid to 1010(used by docker-compose)
    plex_user=$(grep plex /etc/passwd)
    
    if [[ -z ${plex_user} ]]; then
      echo "Creating user plex"
      useradd -u 1010 -U -m plex
    fi

    plex_uid=$(id -u plex)
    plex_gid=$(id -g plex)
	  
    if [[ ! -f ${env_file} ]]; then
      touch "${env_file}"
    else
      echo '' > "${env_file}"
    fi

    echo "PUID=${plex_uid}" >> ids.env
    echo "PGID=${plex_gid}" >> ids.env

    ## Add fstab entries to bind mount our media and app config directories
    fstab_media=$(grep "/home/plex/media /media" /etc/fstab)
    fstab_apps=$(grep "/home/plex/apps /apps" /etc/fstab)

    if [[ ! ${fstab_media} ]]; then
		  echo "Adding /media bind mount to /etc/fstab"
		  cat <<- 'EOF' >> /etc/fstab	
/home/plex/media /media none defaults,bind 0 0
EOF
    else
      echo "/media fstab entry exists"
    fi
	
	  if [[ ! ${fstab_apps} ]]; then
		  echo "Adding /apps bind mount to /etc/fstab"
		  cat <<- 'EOF' >> /etc/fstab	
/home/plex/apps /apps none defaults,bind 0 0
EOF
    else
      echo "/apps fstab entry exists"
    fi

    ## Create the /apps and /media directories
    if [[ ! -d "/apps" ]]; then
      echo "Creating /apps"
      mkdir /apps
    fi

    if [[ ! -d "/media" ]]; then
      echo "Creating /media"
      mkdir /media
    fi

    if [[ ! -d "/home/plex/media" ]] && [[ ! -d "/home/plex/media" ]]; then
      echo "Creating /home/plex/media and /home/plex/apps"
      mkdir -p /home/plex/{apps,media}
      chown plex:plex /home/plex/{apps,media}
    fi
    
      ## bind mount the /apps and /media directories
    apps_mount=$(mount | grep "/home/plex/apps")
    media_mount=$(mount | grep "/home/plex/media")
    if [[ ! ${apps_mount} ]]; then
      echo "Mounting /apps"
      mount /apps
    fi
    
    if [[ ! ${media_mount} ]]; then
      echo "Mounting /Media"
      mount /media
    fi

    ## Create directory trees
    if [[ ! -d ${config_dir} ]]; then
      echo "Creating ${config_dir}"
      mkdir -p /apps/configs
    fi

    for serv in "${services[@]}"; do
      s_create="${config_dir}/${serv}"
      if [[ ! -d "${s_create}" ]]; then
        echo "Creating ${s_create}"
        mkdir "${s_create}"
      else
        echo "${s_create} already exists, skipping..."
      fi
    done
    
    echo "Creating Media Directories"
    declare -a media_dirs=(movies tv downloads)
    
    for dir in "${media_dirs[@]}"; do
      m_create="/media/${dir}"
      if [[ ! -d "${m_create}" ]]; then
        echo "Creating ${m_create}"
        mkdir -p "${m_create}"
      else
        echo "${m_create} already exists, skipping..."
      fi
    done

    if [[ ! -d "/media/downloads/nzb" ]]; then
      echo "Creating: "
      echo " - /media/downloads/nzb"
      echo " - /media/downloads/nzb/completed"
      echo " - /media/downloads/nzb/intermediate"
      mkdir -p "/media/downloads/nzb/"{completed,intermediate}
    else
      echo "/media/downloads/nzb already exists, skipping"
    fi

    echo "Changing Directory Ownership"
    chown -R plex:plex /media /apps

      ## Create home for the the docker-compose.yml and copy it there
    
    if [[ ${has_systemd} -eq 1 ]]; then
      ## Create directory to store docker-compose files
      echo "Creating application directory at ${app_dir}"
      mkdir -p ${app_dir}/
      
      ## Move files to new directory
      echo "Moving docker compose to application directory"
      cp "${yml_file}" "${app_dir}/"
      mv "${env_file}" "${app_dir}/"

      ## Generate a systemd service file and move it to /etc/systemd/system
      generate_unit_file
      
      if [[ -f ${unit_file} ]]; then
        cp "${unit_file}" /etc/systemd/system/
      else
        echo "Unit file not found, something may have gone wrong generating"
      fi
        
      ## Reload systemd daemon to load new service file
      "${systemctl}" daemon-reload
      
      ## Install firewalld zone and activate
      if [[ ${has_firewalld} -eq 1 ]]; then
        echo "Installing firewall rules"
        install_firewalld_zone
      fi

      ## Enable service
      echo "Enabling compose-mediaserver.service"
      "${systemctl}" enable compose-mediaserver.service 
      
      echo "Run systemctl start compose-mediaserver.service to start"
      touch "${app_dir}/.setup_run"
    
    else  
      touch "${script_dir}/.setup_run"
      echo "Run docker-compose up -d from: ${script_dir}"	
    fi
    
    echo "Setup Complete"
}

## Function used to generate a systemd unit file with the proper configs
function generate_unit_file() {
	cat << EOF > "${unit_file}"
[Unit]
Requires=docker.service
After=docker.service

[Service]
User=root
Restart=on-failure
ExecPreStart=${docker_compose} -f ${app_dir}/docker-compose.yml pull
ExecStart=${docker_compose} -f ${app_dir}/docker-compose.yml up
ExecStop=${docker_compose} -f ${app_dir}/docker-compose.yml down

[Install]
WantedBy=default.target
EOF

}

function install_firewalld_zone() {
  echo "Creating zone file"
  cp firewalld-zone.xml /etc/firewalld/zones/MediaServer.xml
  echo "Setting active and default zone to MediaServer"
  firewall-cmd --permanent --set-default-zone=MediaServer
  echo "Reloading firewalld"
  firewall-cmd --complete-reload
}

install_docker
tests "${docker}" "${docker_compose}" "${systemctl}" "${firewalld}"
setup 
