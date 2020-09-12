#!/bin/bash
INPUT_FILE="./data/share-links.txt"
OUTPUT_FILE="./output/stream-links.txt"
OUTPUT_ASSETS_DIR="./output/assets"
OUTPUT_TEMP_ASSETS_DIR="./output/assets/temp"
URL_CONVERTER_BIN="./lib/wave_url_converter"
URL_REGEX="http[^ ]*"
LIMIT_SPEED=""
PARALLEL_PROCESS=""

function print_save_output_prompt {
    echo "Do you want to save the output?"
}

function print_download_resource_prompt {
    echo "Would you like to download the podcast resources?"
}

function read_user_input {
    select response in "Yes" "No"; do
        case "$response" in
            Yes) echo true; exit;;
            No) exit;;
        esac
    done
}

function __get_id_link_pair {
    local id=$1
    local link=$2

    echo "$id,$link"
}

function __parse_id_and_link {
    local input_file=$1

    local id
    local link
    while read -r line; do

        [[ "$line" =~ ($URL_REGEX) ]]
        if [[ -z "${BASH_REMATCH[1]}" ]]; then
            id="$line"
        else
            link="${BASH_REMATCH[1]}"
            __get_id_link_pair "$id" "$link"
        fi

    done < "$input_file"
}

function __get_asset_title {
    local id=$1

    echo "Dial $id"
}

function __get_updated_wave_link {
    local link=$1

    eval "$URL_CONVERTER_BIN" "\"$link\""
}

function convert_input_file {
    local pairs
    pairs=$(__parse_id_and_link "$INPUT_FILE")
    while IFS=',' read -r id link; do
        __get_asset_title "$id"
        __get_updated_wave_link "$link"
    done <<< "$pairs"
}

function highlight_links {
    local text=$1
    local PURPLE_ESC_CODE="\033[0;35m"
    local NO_CLR_CODE="\033[0m"

    while read -r line; do
        [[ "$line" =~ (^.*)($URL_REGEX) ]]
        if [[ -z "${BASH_REMATCH[2]}" ]]; then
            echo "$line"
        else
            echo -e "${BASH_REMATCH[1]}${PURPLE_ESC_CODE}${BASH_REMATCH[2]}${NO_CLR_CODE}"
        fi
    done <<< "$text"
}

function write_to_output_file {
    local content=$1
    echo "$content" > "$OUTPUT_FILE"
}

function scrape_webpage_for_uri {
    local link=$1

    local webpage_html
    webpage_html=$(curl -s "$link")

    local VIDEO_SRC_REGEX="(https?:[^:]*mp4)"
    [[ "$webpage_html" =~ $VIDEO_SRC_REGEX ]]
    if [[ -n "${BASH_REMATCH[1]}" ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

function __get_content_length {
    local uri=$1

    local key_val
    local HEADER_REGEX="^content-length"
    key_val=$(curl -s -I "$uri" |
                  grep "$HEADER_REGEX")


    [[ "$key_val" =~ ([0-9]+) ]]
    echo "${BASH_REMATCH[1]}"
}

function __partition_number_range {
    local start=$1
    local end=$2
    local blocks=$3

    # default for division is floor
    local gap=$(( ("$end" - "$start") / "$blocks" ))
    local block_iter="$start"

    local block_end
    while [[ "$block_iter" -lt "$end" ]]; do
        block_end=$(( block_iter + gap ))

        if [[ "$block_end" -gt "$end" ]]; then
            block_end="$end"
        fi

        echo "${block_iter}-${block_end}"
        block_iter="$(( block_end + 1 ))"
    done
}

function __get_asset_file_name {
    local id=$1
    echo "$OUTPUT_ASSETS_DIR/${id}.mp4"
}

function __get_temp_asset_file_name {
    local id=$1
    echo "$OUTPUT_TEMP_ASSETS_DIR/${id}.mp4"
}

function __append_block_extension {
    local file_name=$1
    local num=$2

    echo "${file_name}.part${num}"
}

function __download_uri_block {
    local uri=$1
    local asset_id=$2
    local byte_range=$3
    local block_num=$4
    local silent=$5

    local temp_asset_file
    temp_asset_file="$(__get_temp_asset_file_name "$asset_id")"

    local block_name
    block_name="$(__append_block_extension "$temp_asset_file" "$block_num")"

    if [[ -e "$block_name" ]]; then
        echo "File-block exists, skipping: $block_name"
    else
        echo "Downloading: $block_name"

        local arg_list
        arg_list="--progress-bar --create-dirs"
        arg_list+=" --range \"$byte_range\""
        arg_list+=" -o \"$block_name\""

        if [[ "$silent" == "true" ]]; then
            arg_list+=" --silent"
        fi

        if [[ -n "$LIMIT_SPEED" ]]; then
            arg_list+=" --limit-rate $LIMIT_SPEED"
        fi

        eval "curl" "$arg_list" "$uri"
    fi
}

function __combine_uri_blocks {
    local asset_id=$1

    local temp_asset_file
    temp_asset_file="$(__get_temp_asset_file_name "$asset_id")"

    local output_file
    output_file="$(__get_asset_file_name "$asset_id")"

    cat "$temp_asset_file"* > "$output_file"
}

function __clean_up_uri_blocks {
    local asset_id=$1

    local temp_asset_file
    temp_asset_file="$(__get_temp_asset_file_name "$asset_id")"

    local asset_block
    asset_block="$(__append_block_extension "$temp_asset_file")"
    rm "$asset_block"*
}

function download_uri_in_blocks {
    local uri=$1
    local asset_id=$2

    local content_length
    content_length="$(__get_content_length "$uri")"

    local bytes_ranges
    bytes_ranges="$(__partition_number_range 0 "$content_length" 9)"

    local success="true"
    local counter="1"

    # fd 0 1 2 reserved for stdin, stdout, stderr
    while read -r -u 3 byte_range; do
        __download_uri_block "$uri" "$asset_id" "$byte_range" "$counter" ||
            success="false"

        counter=$(( counter + 1 ))
    done 3<<< "$bytes_ranges"

    if [[ "$success" == "true" ]]; then
        echo "Combining asset parts"
        __combine_uri_blocks "$asset_id" &&
            __clean_up_uri_blocks "$asset_id" &&
            echo "Done combining asset parts"
    fi
}

function download_uri {
    local uri=$1
    local asset_id=$2

    local asset_file
    asset_file="$(__get_asset_file_name "$asset_id")"
    if [[ -e "$asset_file" ]]; then
        echo "File exists, skipping: $asset_file"
    else
        download_uri_in_blocks "$uri" "$asset_id"
    fi
}

function download_assets {
    local uri
    local pairs
    pairs=$(__parse_id_and_link "$OUTPUT_FILE")
    while IFS=',' read -r asset_id link; do
        uri=$(scrape_webpage_for_uri "$link")
        download_uri "$uri" "$asset_id"
    done <<< "$pairs"
}

function process_arg_flags {
    while getopts ":l:p:" option; do
        case "$option" in
            l)
                # validate input to be of form [num]k
                LIMIT_SPEED="$OPTARG"
                [[ "$LIMIT_SPEED" =~ (^[0-9]+)([kKmMgG]$) ]]
                if [[ -z "${BASH_REMATCH[1]}" ]] ||
                       [[ -z "${BASH_REMATCH[2]}" ]]; then
                    echo "Arg limit-speed used incorrectly. Ensure the format is: 500k"
                    exit 1
                fi
                ;;
            p)
                PARALLEL_PROCESS="$OPTARG"
                ;;
            \?)
                echo "Use: [-l] limit-speed, [-p] parallel-processes"
                exit 1
                ;;
        esac
    done

    shift "$(( OPTIND - 1 ))"
}

function main {
    process_arg_flags "$@"

    local updated_input
    updated_input="$(convert_input_file)"
    highlight_links "$updated_input"

    local overwrite_output_file
    print_save_output_prompt
    overwrite_output_file=$(read_user_input)
    if [[ "$overwrite_output_file" == true ]]; then
        write_to_output_file "$updated_input"

        local download_resource
        print_download_resource_prompt
        download_resource=$(read_user_input)
        if [[ "$download_resource" == true ]]; then
            download_assets
        fi
    fi
}

main "$@"
