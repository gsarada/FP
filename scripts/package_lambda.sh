#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)" 

MODULE="${1:-}" 

if [[ -z "${MODULE}" ]]; then 
    echo "Usage: $0 <module>" 
    exit 1 
fi 

############################################################################### 
# Module configuration 
###############################################################################

PACKAGE_TYPE="" 
DEPENDENCY="" 
APPS=()

case "${MODULE}" in

    ingestion)
        PACKAGE_TYPE="zip"
        DEPENDENCY=""
        APPS=("ingestion")
        ;;

    researcher)
        PACKAGE_TYPE="image"
        DEPENDENCY=""
        APPS=("researcher")
        ;;

    agents)
        PACKAGE_TYPE="zip"
        DEPENDENCY="database"
        APPS=("planner" "reporter" "charter" "retirement" "tagger")
        ;;

    frontend)
        PACKAGE_TYPE="zip"
        DEPENDENCY=""
        APPS=("api")
        ;;

    *)
        echo "Module '${MODULE}' is not configured. Nothing to package."
        exit 0
        ;;

esac


get_app_dir() { 
    
    local module="$1" 
    local app="$2" 
    local module_dir="${PROJECT_ROOT}/app/${module}" 
    
    if [[ "${#APPS[@]}" -eq 1 && "${app}" == "${module}" ]]; then 
        echo "${module_dir}" 
    else 
        echo "${module_dir}/${app}" 
    fi 
}
###############################################################################
# Validation
###############################################################################

if [[ "${PACKAGE_TYPE}" == "zip" ]]; then
    
    command -v uv >/dev/null 2>&1 || {
        echo "ERROR: uv is not installed."
        exit 1
    }
 
    command -v zip >/dev/null 2>&1 || {
        echo "ERROR: zip is not installed."
        exit 1
    }

elif [[ "${PACKAGE_TYPE}" == "image" ]]; then 
    
    command -v docker >/dev/null 2>&1 || { 
        echo "ERROR: Docker is not installed." 
        exit 1 
    }

fi

############################################################################### 
# Package ZIP Lambda 
############################################################################### 

package_zip() { 
    
    local module="$1" 
    local dependency="$2" 
    shift 2 
    
    local module_dir="${PROJECT_ROOT}/app/${module}" 
    
    if [[ ! -d "${module_dir}" ]]; then 
        echo "ERROR: Module directory not found:${module_dir}" 
        exit 1 
    fi 
    
    for app in "$@"; do 
        
        local app_dir
        app_dir="$(get_app_dir "${module}" "${app}")" 

        local build_dir="${app_dir}/build/" 
        local package_dir="${build_dir}/package" 
        local zip_file="${app_dir}/${app}_lambda.zip" 
    
        echo "------------------------------------------" 
        echo "Packaging: ${app}" 
        echo "------------------------------------------" 
        
        if [[ ! -d "${app_dir}" ]]; then 
            echo "ERROR: Application directory not found: ${app_dir}" 
            exit 1 
        fi 
        
        ####################################################################### 
        # Clean previous build 
        ####################################################################### 
        rm -rf "${build_dir}" 
        rm -f "${zip_file}" 
        mkdir -p "${package_dir}" 
        
        ####################################################################### 
        # Export dependencies from uv.lock # 
        ####################################################################### 
        echo "Exporting dependencies..." 
        ( 
            uv export --directory "${app_dir}/src" --no-hashes --no-emit-project --format requirements-txt > "${build_dir}/requirements.txt" 
        ) 
        
        ####################################################################### 
        # Install dependencies 
        ####################################################################### 
        echo "Installing dependencies..." 
        ( 
            uv pip install --no-cache --python-platform x86_64-manylinux_2_28 --python-version 3.12  --target "${package_dir}" -r "${build_dir}/requirements.txt" 
        ) 
        
        ####################################################################### 
        # Copy application 
        ####################################################################### 
        echo "Copying application..." 
        
        rsync -r --exclude="test*" "${app_dir}/src/" "${package_dir}/" 
        
        ####################################################################### 
        # Copy shared dependency 
        ####################################################################### 
        if [[ -n "${dependency}" ]]; then 
            local dependency_path="${PROJECT_ROOT}/app/${dependency}" 
        
            if [[ ! -d "${dependency_path}" ]]; then 
                echo "ERROR: Dependency not found: ${dependency_path}"
                exit 1 
            fi 
            
            echo "Copying dependency: ${dependency}" 
            
            cp -R "${dependency_path}/src" "${package_dir}/" 
        fi 
        
        ####################################################################### 
        # Create ZIP 
        ####################################################################### 
        echo "Creating ZIP..." 
        ( 
            cd "${package_dir}" 
            zip -qr "${zip_file}" . 
        ) 
        
        local size 
        size=$(du -h "${zip_file}" | cut -f1) 
        
        echo "Created: ${zip_file}, Size: ${size}" 
        
    done 
}

############################################################################### 
# Package Container Image 
############################################################################### 
package_image() { 
    
    local module="$1" 
    shift 
    
    local module_dir="${PROJECT_ROOT}/app/${module}" 
    
    if [[ ! -d "${module_dir}" ]]; then 
        echo "ERROR: Module directory not found:${module_dir}" 
        exit 1 
    fi 
    
    for app in "$@"; do 
        local app_dir
        app_dir="$(get_app_dir "${module}" "${app}")" 
        
        if [[ ! -d "${app_dir}" ]]; then 
            echo "ERROR: Application directory not found:${app_dir}" 
            exit 1 
        fi 
        
        if [[ ! -f "${app_dir}/Dockerfile" ]]; then 
            echo "ERROR: Dockerfile not found: ${app_dir}/Dockerfile" 
            exit 1 
        fi 
        
        local image_name="${app}:latest" 
        
        echo "------------------------------------------" 
        echo "Building container: ${image_name}" 
        echo "------------------------------------------" 
        
        docker build --platform linux/amd64 --provenance=false -t "${image_name}" "${app_dir}" 
            
        echo "Created image:${image_name}" 
    done 
} 

############################################################################### 
# Dispatch based on package type 
############################################################################### 

case "${PACKAGE_TYPE}" in 
    zip) 
        package_zip  "${MODULE}" "${DEPENDENCY}" "${APPS[@]}" 
        ;; 
    
    image) 
        package_image "${MODULE}" "${APPS[@]}" 
        ;; 
    
    *) 
        echo "ERROR: Unsupported package type '${PACKAGE_TYPE}'." 
        exit 1 
        ;; 
esac 

echo "==========================================" 
echo "Packaging completed successfully" 
echo "Module: ${MODULE}" 
echo "=========================================="

