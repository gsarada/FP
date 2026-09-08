#!/usr/bin/env bash

set -euo pipefail

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
        APPS=("ingestion")
        ;;

    researcher)
        PACKAGE_TYPE="image"
        APPS=("researcher")
        ;;

    agents)
        PACKAGE_TYPE="zip"
        DEPENDENCY="database"
        APPS=("planner" "reporter" "charter" "retirement" "tagger")
        ;;

    api)
        PACKAGE_TYPE="zip"
        DEPENDENCY="database"
        APPS=("api")
        ;;

    frontend)
        PACKAGE_TYPE="node"
        APPS=("frontend")
        ;;

    *)
        echo "ERROR: Module '${MODULE}' is not configured."
        exit 1
        ;;

esac

###############################################################################
# Application directory
###############################################################################

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
# Validate commands
###############################################################################

require_command() {

    local command="$1"

    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: '${command}' is not installed."
        exit 1
    fi
}

###############################################################################
# Package ZIP Lambda
###############################################################################

package_zip() {

    local module="$1"
    local dependency="$2"

    shift 2

    local module_dir="${PROJECT_ROOT}/app/${module}"

    [[ -d "${module_dir}" ]] || {
        echo "ERROR: Module directory not found: ${module_dir}"
        exit 1
    }

    require_command uv
    require_command docker
    require_command zip
    require_command rsync

    for app in "$@"; do

        local app_dir
        local build_dir
        local package_dir
        local zip_file

        app_dir="$(get_app_dir "${module}" "${app}")"
        build_dir="${app_dir}/build"
        package_dir="${build_dir}/package"
        zip_file="${app_dir}/${app}_lambda.zip"

        [[ -d "${app_dir}" ]] || {
            echo "ERROR: Application directory not found: ${app_dir}"
            exit 1
        }

        echo
        echo "------------------------------------------"
        echo "Packaging Lambda: ${app}"
        echo "------------------------------------------"

        rm -rf "${build_dir}"
        rm -f "${zip_file}"

        mkdir -p "${package_dir}"

        echo "Exporting dependencies..."

        uv export \
            --directory "${app_dir}/src" \
            --no-hashes \
            --no-emit-project \
            --format requirements-txt \
            > "${build_dir}/requirements.txt"

        echo "Installing dependencies..."

        docker run --rm \
            --platform linux/amd64 \
            -v "${package_dir}:/var/task" \
            -v "${build_dir}/requirements.txt:/tmp/requirements.txt" \
            public.ecr.aws/lambda/python:3.12 \
            /bin/sh -c \
            "pip install --no-cache-dir \
             -r /tmp/requirements.txt \
             -t /var/task"

        echo "Copying application..."

        rsync -r \
            --exclude="test*" \
            --exclude="__pycache__" \
            --exclude="*.pyc" \
            --exclude=".env*" \
            "${app_dir}/src/" \
            "${package_dir}/"

        if [[ -n "${dependency}" ]]; then

            local dependency_path="${PROJECT_ROOT}/app/${dependency}"

            [[ -d "${dependency_path}" ]] || {
                echo "ERROR: Dependency not found: ${dependency_path}"
                exit 1
            }

            echo "Copying dependency: ${dependency}"

            cp -R \
                "${dependency_path}/src" \
                "${package_dir}/"

        fi

        echo "Creating ZIP..."

        (
            cd "${package_dir}"
            zip -qr "${zip_file}" .
        )

        echo "Created: ${zip_file}"
        echo "Size: $(du -h "${zip_file}" | cut -f1)"

    done
}

###############################################################################
# Package container image
###############################################################################

package_image() {

    local module="$1"

    shift

    require_command docker

    local module_dir="${PROJECT_ROOT}/app/${module}"

    [[ -d "${module_dir}" ]] || {
        echo "ERROR: Module directory not found: ${module_dir}"
        exit 1
    }

    for app in "$@"; do

        local app_dir
        local image_name

        app_dir="$(get_app_dir "${module}" "${app}")"
        image_name="${app}:latest"

        [[ -f "${app_dir}/Dockerfile" ]] || {
            echo "ERROR: Dockerfile not found: ${app_dir}/Dockerfile"
            exit 1
        }

        echo
        echo "------------------------------------------"
        echo "Building container: ${image_name}"
        echo "------------------------------------------"

        docker build \
            --platform linux/amd64 \
            --provenance=false \
            -t "${image_name}" \
            "${app_dir}"

    done
}

###############################################################################
# Build Node / NextJS application
###############################################################################

build_node() {

    local module="$1"

    local app_dir="${PROJECT_ROOT}/app/${module}"
    local out_dir="${app_dir}/out"

    require_command npm

    [[ -d "${app_dir}" ]] || {
        echo "ERROR: Module directory not found: ${app_dir}"
        exit 1
    }

    echo
    echo "------------------------------------------"
    echo "Building frontend"
    echo "------------------------------------------"

    if [[ ! -d "${app_dir}/node_modules" ]]; then

        echo "Installing dependencies..."

        if [[ -f "${app_dir}/package-lock.json" ]]; then
            npm ci --prefix "${app_dir}"
        else
            npm install --prefix "${app_dir}"
        fi

    fi

    echo "Building NextJS application..."

    NODE_ENV=production \
        npm run build --prefix "${app_dir}"

    [[ -d "${out_dir}" ]] || {
        echo "ERROR: Frontend build output not found: ${out_dir}"
        exit 1
    }

    echo "Frontend build completed."

}

###############################################################################
# Dispatch
###############################################################################

case "${PACKAGE_TYPE}" in

    zip)
        package_zip "${MODULE}" "${DEPENDENCY}" "${APPS[@]}"
        ;;

    image)
        package_image "${MODULE}" "${APPS[@]}"
        ;;

    node)
        build_node "${MODULE}"
        ;;

    *)
        echo "ERROR: Unsupported package type '${PACKAGE_TYPE}'."
        exit 1
        ;;

esac

echo
echo "=========================================="
echo "Packaging completed successfully"
echo "Module: ${MODULE}"
echo "=========================================="