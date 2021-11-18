#!/bin/bash
# Bash_WP-CLI_Update 1.0
# Mikhail Deynekin | https://fb.com/Deynekin
# https://github.com/paulmann/Bash_WP-CLI_Update

wp cli update --allow-root

# Array of WP sites:  '[WP Root Folder] | [User] | [WP Domain]'
declare -a arr=(
	'/var/www/md/data/www/paulman.ru/news | md | news.paulman.ru'
	'/var/www/md/data/www/iya.ru'
	'/var/www/md/data/www/sukulent.ru'
	)


declare -a wpc=(
	'wp core update'
	'wp plugin update --all'
	'wp core update-db'
	'wp cron event run --all'
	'wp cache flush'
	'wp db repair'
	'wp db optimize'
)
#	'wp theme auto-updates enable --all'
#	'wp theme update --all'

for i in "${arr[@]}"
do
	IFS=' | ' read -r -a arr <<< ${i}
	PTH="${arr[0]}"
	USR="${arr[1]}"
	DMN="${arr[2]}"
	IFS='/' read -r -a arr <<< ${arr[0]}
	[[ -v USR ]]; USR=${arr[3]}
	[[ ! "${DMN}" ==  *"."* ]] && DMN=${arr[-1]}
	echo "User   : ${USR}"
	echo "Domain : ${DMN}"
	echo "Path   : ${PTH}"

	ELMNTS=$((${#arr[@]}-2))
	tPTH=''
	for ((x=1; x<ELMNTS; x++))
	do
		tPTH+="/${arr[${x}]}"
	done
	HOMEDIR=${tPTH}
	echo "Home   : ${HOMEDIR}"

	for WPCL in "${wpc[@]}"
	do
#		WPCL="wp plugin update --all"
		EXPT="export HOMEDIR=${HOMEDIR} && export HTTP_HOST=${DMN} && cd ${PTH}  && ${WPCL}"
		CMND="su - '${USR}' -c '${EXPT}'"
		echo ${CMND}
		su - ${USR} -c "${EXPT}"
	done

	echo "---------------"
done
exit


