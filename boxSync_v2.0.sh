#! /bin/bash
clear

# Fichier de log
	logFile=boxSync_$(date +%Y%m%d_%H).log
	
# Fonctions
function install(){
	# On enregistre les acces a box.net pour davfs2
	if [[ `id -u` == 0 ]]; then
		echo "Vous ne devez pas etre root"
		sleep 5
		exits
	fi

	# On verifie que davfs2, sudo, rsync, inotify sont installés ou activés
	if [[ `command -v mount.davfs|wc -l` -lt 1 ]]; then
		echo "Vous devez installer DAVFS2 pour la prise en charge de WebDAV" 
		echo "http://techiech.blogspot.fr/2013/04/mounting-webdav-directory-in-linux.html"
		sleep 3
		exit
	else
		if [[ `command -v sudo|wc -l` -lt 1 ]];
		then
			echo "Vous devez installer ou activer votre compte sudoer"
			sleep 3
			exit
		else
			if [[ `command -v rsync|wc -l` -lt 1 ]];
			then
				echo "Vous devez installer rsync"
				sleep 3
				exit
			else
				if [[ `command -v inotifywait|wc -l` -lt 1 ]];
				then
					echo "Vous devez installer inotify-tools"
					sleep 3
					exit
				fi
			fi
		fi
	fi

	echo "*** On lance l'installation ***"
	echo 	
	# On prépare le montage webdav automatique de box.net
	if [ ! -f ~/.davfs2/secrets ];
	then
		userServerDAV="https://dav.box.com/dav"
		read -p "Serveur Box.com [ https://dav.box.com/dav ]: " userServerDAV
		if [ -z $userServerDAV ];
		then
			serverDAV=$userServerDAV
		fi
		
		read -p "Identifiant Box.com: " username
		echo -n "Password (ne s'affiche pas): " 
		read -s password
		echo
		if [ ! -d ~/.davfs2 ];
		then
			mkdir ~/.davfs2
		fi
		echo "$serverDAV $username $password" >> ~/.davfs2/secrets
		chmod 0600 ~/.davfs2/secrets
		
		# On ajoute dans fstab le montage du WebDAV box.net
		if [[ `id -u` != 0 ]]; then
			cp -a /etc/fstab ~/fstab
			
			echo >> ~/fstab
			echo "# Sync $serverDAV" >> ~/fstab
			echo "$serverDAV /mnt/boxDotCom         davfs rw,users,noauto 0 0" >>~/fstab
			echo >> ~/fstab
			echo
			echo "On active le montage automatique du WebDAV de Box.com"
			sudo mv /etc/fstab /etc/fstab.sauv_$(date +%s)
			sudo mv ~/fstab /etc/fstab
			sudo chown root:root /etc/fstab
			sudo mkdir -p /mnt/boxDotCom
			sudo usermod -a -G davfs2 $USER
			sudo chmod u+s /sbin/mount.davfs
			
		fi

	fi

	# On choisi le repertoire à synchroniser
	if [ ! -f ~/.boxdotcom_sync.conf ] && [ ! -f ~/.boxdotcom_bckp.conf ];
	then
		echo
		echo "Vous devez choisir un répertoire de votre machine à synchroniser vers Box.com"
		echo "Le chemin doit etre complet en commencant par / sinon il sera considéré comme étant dans votre \$HOME"
		while true
		do
			echo
			read -p "chemin vers le répertoire [ /home/`whoami`/syncToBox ]: " folderToSync
			if [ -z $folderToSync ];
			then
				echo "/home/`whoami`/syncToBox"> ~/.boxdotcom.conf
			else
				echo $folderToSync> ~/.boxdotcom.conf
			fi

			pathTmp=`cat ~/.boxdotcom.conf`
			if [[ $pathTmp =~ ^/ ]];
			then
				webDAV="`cat ~/.boxdotcom.conf`"
			else
				webDAV=~/"`cat ~/.boxdotcom.conf`"
			fi

			if [ ! -d $webDAV ];
			then
				mkdir -p $webDAV 2>/dev/null
				if [ $? -ne 0 ];
				then
					echo "Impossible de créer le répertoire $webDAV"
				else
					break
				fi
			else
				break
			fi
		done
		# On determine le type de synchronisation.
		clear
		echo
		echo "- Mode Synchronisation: votre machine sera identique à Box.com"
		echo "- Mode Sauvegarde: Box.com conserve toutes les données meme celles que vous supprimez sur votre machine."
		echo "		Pour supprimer un document obsolete vous devez le faire directement sur Box.com"
		echo
		read -p "Quel mode vous voulez utiliser, Synchonisation (s) ou Sauvegarde (b) [b] ?: " syncMod
		if [ "${syncMod,,}" == "b" ];
		then
			mv ~/.boxdotcom.conf ~/.boxdotcom_bckp.conf
		else
			mv ~/.boxdotcom.conf ~/.boxdotcom_sync.conf
		fi

	fi
	
	# On le lance au démarrage de la session
	cp -a -f $0 ~/bin/
	chmod u+x ~/bin/`basename $0`
	echo >>~/.profile
	echo \$HOME/bin/`basename $0 &`>>~/.profile
}

function getConfig (){
	# On récupère le fichier de configuration
	if [ -f ~/.boxdotcom_sync.conf ];
	then
		pathTmp=`cat ~/.boxdotcom_sync.conf`
		syncMod="--delete"
	else
		pathTmp=`cat ~/.boxdotcom_bckp.conf`
		syncMod=""
	fi
	
	if [[ $pathTmp =~ ^/ ]];
	then
		webDAV="$pathTmp"
	else
		webDAV=~/"$pathTmp"
	fi
	
	# On récupère l'URL du serveur
	serverDAV=`cat ~/.davfs2/secrets|cut -d" " -f1|cut -d/ -f3`
	
	# Configuration pour inotifywait du MAIN
	DIR=$webDAV
	EVENTS="create"
	EVENTS1="move"
	EVENTS2="modify"
}

function syncBox(){	
	# On verifie que la synchronisation n'est pas déja en cours
	_check=`ps aux|grep rsync|grep $webDAV|wc -l`
	if [ $_check -gt 2 ]
	then
		return
	fi

	# On vérifie que Box.com est joignable
	ping -c 1 google.com > /dev/null 2>&1
	if [ $? -ne 0 ]
	then
		echo >"$webDAV/offline.log"
		clear
		echo "Mode offline"
		return
	fi
	
	# On verifie box.net est monté en WebDAV
	if [ $(mount|grep /mnt/boxDotCom |wc -l) -eq 0 ];
	then
		echo "Box WEBDAV box.com is not mounted: "`date` >> $webDAV/$logFile
		mount /mnt/boxDotCom
		echo "=======" >>$webDAV/$logFile
		echo >>$webDAV/$logFile
	fi

	# On commence la synchronisation
	if [ $(mount|grep /mnt/boxDotCom |wc -l) -eq 1 ];
	then
		clear
		echo Envoie vers Box.net en cours...
		echo 
		echo === debut : `date` >>$webDAV/$logFile
		echo >>$webDAV/$logFile
		#
		# Il ne faut pas l'option -a car davfs ne support pas le changement de permission (-p) du fichier
		#	http://stackoverflow.com/questions/25922436/rsync-on-a-webdav-folder-doesnt-work
		#	http://serverfault.com/questions/141773/what-is-archive-mode-in-rsync
		#		-a équivaut à -rlptgoD
		#
		# Il ne faut pas se baser sur la date des fichiers pour la synchronisation, davfs ne gère pas correctement les changements de date,
		#   on se base alors sur le checksum --omit-dir-times --checksum
		#	http://unix.stackexchange.com/questions/78933/rsync-mkstemp-failed-invalid-argument-22-with-davfs-mount-of-box-com-cloud
		#
		if [ -f "$webDAV/offline.log" ];
		then
			# Synchro offline machine vers box.com
			echo "Synchronisation : Machine vers le serveur."
			rsync -rltgoD -vz --stats -h --omit-dir-times --checksum --log-file=$webDAV/$logFile --exclude='lost+found' --exclude='.*' --exclude='*.log' "$webDAV/" /mnt/boxDotCom
			
			# Synchro offline box.com vers machine
			echo
			echo "Synchronisation : Serveur vers la machine."
			rsync -rltgoD -vz --stats -h --omit-dir-times --checksum --log-file=$webDAV/$logFile --exclude='lost+found' --exclude='.*' --exclude='*.log' /mnt/boxDotCom/ "$webDAV"
			
			# On ré-active la synchronisation normale
			rm -f "$webDAV/offline.log"
			if [ -f "$webDAV/initSync.log" ];
			then
				rm -f "$webDAV/initSync.log"
			fi
		else
			if [ -f "$webDAV/initSync.log" ];
			then
				# Synchro initiale box.com vers machine
				echo "Premiere synchronisation : Serveur vers la machine."
				rsync -rltgoD -vz --stats -h --omit-dir-times --checksum --log-file=$webDAV/$logFile --exclude='lost+found' --exclude='.*' --exclude='*.log' /mnt/boxDotCom/ "$webDAV"
				
				# Synchro initiale machine vers box.com
				echo
				echo "Premiere synchronisation : Machine vers le serveur."
				rsync -rltgoD -vz --stats -h --omit-dir-times --checksum --log-file=$webDAV/$logFile --exclude='lost+found' --exclude='.*' --exclude='*.log' "$webDAV/" /mnt/boxDotCom
				
				# On ré-active la synchronisation normale
				rm -f "$webDAV/initSync.log"
			else
				# Synchro normale
				rsync -rltgoD -vz $syncMod --stats -h --omit-dir-times --checksum --log-file=$webDAV/$logFile --exclude='lost+found' --exclude='.*' --exclude='*.log' "$webDAV/" /mnt/boxDotCom
			fi
		fi
		
			
		echo >>$webDAV/$logFile
		echo === Fin : `date` >>$webDAV/$logFile
		echo >>$webDAV/$logFile
	fi

	# On supprime les logs de plus de 60 minutes
	find $webDAV/ -maxdepth 1 -name 'boxSync*' -cmin +60 -delete
}

### MAIN ###
############

# Installation
if [ ! -f $HOME/.boxdotcom_sync.conf ] && [ ! -f $HOME/.boxdotcom_bckp.conf ];
then
	install
	source ~/.profile
	exit
fi

clear
getConfig

# On verifie que le programme n'est pas déja en cours
_check2=`ps aux|grep inotifywait|grep $webDAV|wc -l`
if [ $_check2 -gt 1 ]
then
	exit
fi
	
# On lance une premier synchro
echo >"$webDAV/initSync.log"
syncBox

clear
echo "En attente, surveillance d'activité du répertoire $DIR..."
echo
# http://kerlinux.org/2010/08/utilisation-de-inotifywait-dans-des-scripts-shell/
# http://stackoverflow.com/questions/10533200/processing-data-with-inotify-tools-as-a-daemon
nohup inotifywait -mrq --exclude '.*/\..*' --exclude '.*/.*\.log' -e $EVENTS -e $EVENTS1 -e $EVENTS2 --timefmt '%Y-%m-%d %H:%M:%S' --format '%T %:e %f' "$DIR" 2>/dev/null |
while read date time action file
do
	syncBox
    echo
    echo "===> Envoie terminé"
    #action=${action:0:5}
	#case $action in
	#	"MOVED")
	#	echo "MOVED OR MODIFY OR DELETE: $file"
	#	# Command_bis
	#	;;
	#	
	#	"CREAT")
	#	echo "CREATE: $file"
	#	# Command_bis
	#	;;
	#esac
	sleep 5
	clear
	echo "En attente, surveillance d'activité du répertoire $DIR..."
	echo		
done &

## Erreur possible
#
# http://ubuntuforums.org/showthread.php?t=202761&page=4
# rsync: rename xxx: Input/output error (5)
#
# editer davfs2.conf et fixer use_locks à 0
#
