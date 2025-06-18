#!/usr/bin/env bash
#
# This following script applies ACL permissions to a target path and its specified directory tree. It sets rX permissions on intermediate directories
# and recursively applies ACL from an input file (or from prompts) from the target directory downward.
#
# Author:  Thomas Beaudry
# Date:    Feb 2025
#
set -euo pipefail

#check usage
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]
then
	echo -e "USAGE: $0 <top_level_path> <target_path> [ACL_file]\nWhere [ACL_file] is optional"
	exit 1
fi

# get paths and remove any extra slashes with 'realpath', also make sure paths are directories
if ! TOP_LEVEL=$(realpath --canonicalize-existing "$1") || [ ! -d "$TOP_LEVEL" ]; then
    echo "ERROR: top_level_path: $1 doesn't exist or is invalid!"
    exit 1
fi

if ! TARGET_PATH=$(realpath --canonicalize-existing "$2") || [ ! -d "$TARGET_PATH" ]; then
    echo "ERROR: target_path: $2 doesn't exist or is invalid!"
    exit 1
fi

ACL_FILE="${3:-}" #optional

#if an ACL file wasn't provided, prompt for a username/group and the desired ACL permissions
if [ -z "${ACL_FILE}" ]
then
	ACL_MODE="ENTRY"

	read -p "Do you want to set ACLs for a (u)ser or a (g)roup? [u/g]: " TYPE
 	#group was selected
	if [[ "${TYPE}" =~ ^[Gg]$ ]]
	then
		read -p "Enter the group name to set ACLs for: " GROUPNAME
		#verify the group exists
		if ! getent group "${GROUPNAME}" &>/dev/null
		then
			echo "ERROR: The group '${GROUPNAME}' doesn't exist!"
			exit 1
		fi
		ACL_TARGET="g:${GROUPNAME}"

	#user was selected
	elif [[ "${TYPE}" =~ ^[Uu]$ ]]
	then
		read -p "Enter the username to set ACLs for: " USERNAME
		#verfiy the user exists
		if ! id "${USERNAME}" &>/dev/null
		then
			echo "ERROR: The user '${USERNAME}' doesn't exist!"
 			exit 1
 		fi
		ACL_TARGET="u:${USERNAME}"
	#invalid choice, exit the script in case the user doesn't know what they are doing
	else
		echo "Invalid choice - try again!"
		exit 1
	fi

	#get and verify the ACL permissions
	read -p "Use the default ACL permissions (rwX) for the user/group [y/n]: " FULL
	if [[ "${FULL}" =~ ^[Yy]$ ]]
	then
		ACL_PERMISSIONS="rwX"
	#prompt for a custom ACL to use if they don't want to use rwX
	elif [[ "${FULL}" =~ ^[Nn]$ ]]
	then
		read -p "Enter custom ACL permissions: " ACL_PERMISSIONS
		#verify that they entered a valid ACL string
		if [[ ! "${ACL_PERMISSIONS}" =~ ^[rwxXtT-]{1,3}$ ]]
		then
			echo "ERROR: Invalid ACL permissions."
			read -p "Re-enter custom ACL permissions: " ACL_PERMISSIONS
			#verify if the second attempt is valid
			if [[ ! "${ACL_PERMISSIONS}" =~ ^[rwxXtT-]{1,3}$ ]]
			then
				echo "ERROR: Invalid ACL permissions. Please research ACLs and try later."
				exit 1
			fi
		fi
        #invalid choice, exit the script in case the user doesn't know what they are doing
        else
                echo "Invalid choice - try again!"
                exit 1
        fi

#an ACL file was provided (so ACL_MODE="FILE")
else
	#verify that the file exists
	if [ ! -f "${ACL_FILE}" ]
	then
		echo "ERROR: The ACL file '${ACL_FILE}' wasn't found!"
		exit 1
	fi
	ACL_MODE="FILE"
fi

#validate that target_path is in top_level_path folder
if [[ "$(realpath "${TARGET_PATH}")" != "$(realpath "${TOP_LEVEL}")"* ]]
then
	echo "ERROR: The target_path: ${TARGET_PATH} folder was not found in the top_level_path: ${TOP_LEVEL} folder!"
	exit 1
fi

#all the checks have been done, so now find intermediate directories between paths
INTERMEDIATE_DIRS=()
CURRENT_PATH="${TARGET_PATH}"

while [ "${CURRENT_PATH}" != "${TOP_LEVEL}" ]; do
    CURRENT_PATH=$(dirname "${CURRENT_PATH}")
    INTERMEDIATE_DIRS+=("${CURRENT_PATH}")
done
INTERMEDIATE_DIRS+=("${TOP_LEVEL}")

#reverse the array to avoid any conflicts when setting permissions
INTERMEDIATE_DIRS=($(echo "${INTERMEDIATE_DIRS[@]}" | tac -s ' '))

#create a tmp acl files to set intermediate ACL permissions
TMP_ACL_FILE=$(mktemp)
if [ "${ACL_MODE}" = "FILE" ]
then
	awk -F: '/^u:|^g:/ {print $1 ":" $2 ":rX"}' "${ACL_FILE}" > "${TMP_ACL_FILE}"
else
	echo "${ACL_TARGET}:rX" > "${TMP_ACL_FILE}"
fi

#use the TMP_ACL_FILE to apply rX ACL to intermediates
for DIR in "${INTERMEDIATE_DIRS[@]}"
do
	echo "Applying rX ACL to ${DIR}"
	setfacl -M "${TMP_ACL_FILE}" "${DIR}"
	if [ $? -ne 0 ]
	then
		echo "ERROR occured while applying rX ACL to ${DIR}!"
		exit 1
	fi
done

#apply ACL permissions recursively to the target_path from the provided acl file
if [ "${ACL_MODE}" = "FILE" ]; then
    echo "Applying ACLs recursively to ${TARGET_PATH} from ACL file"
    setfacl -R -M "${ACL_FILE}" "${TARGET_PATH}"
    echo "Setting default ACLs on ${TARGET_PATH} from ACL file"
    setfacl -dR -M "${ACL_FILE}" "${TARGET_PATH}"

#apply ACL pemisiions using the user entered permissions
else
	echo "Applying ${ACL_PERMISSIONS} ACL recursively to ${TARGET_PATH} for the user/group provided"
	setfacl -R -m "${ACL_TARGET}:${ACL_PERMISSIONS}" "${TARGET_PATH}"
 	echo "Setting default ACLs for user/group on ${TARGET_PATH}"
	setfacl -dR -m "${ACL_TARGET}:${ACL_PERMISSIONS}" "${TARGET_PATH}"
fi

#cleanup
rm -f "${TMP_ACL_FILE}"

echo -e "\nThe ACL permissions have been successfully set!\n"
