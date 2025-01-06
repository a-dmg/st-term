#!/bin/sh

# vim: shiftwidth=4

script_name="$(basename "$0")"

short_help="Usage: $script_name [OPTIONS] <image_file>

This is a script to display images in the terminal using the kitty graphics
protocol with Unicode placeholders. It is very basic, please use something else
if you have alternatives.

Options:
  -h                  Show this help.
  -s SCALE            The scale of the image, may be floating point.
  -c N, --cols N      The number of columns.
  -r N, --rows N      The number of rows.
  --max-cols N        The maximum number of columns.
  --max-rows N        The maximum number of rows.
  --cell-size WxH     The cell size in pixels.
  -m METHOD           The uploading method, may be 'file', 'direct' or 'auto'.
  --speed SPEED       The multiplier for the animation speed (float).
"

# Exit the script on keyboard interrupt
trap "echo 'icat-mini was interrupted' >&2; exit 1" INT

cols=""
rows=""
file=""
tty="/dev/tty"
uploading_method="auto"
cell_size=""
scale=1
max_cols=""
max_rows=""
speed=""

# Parse the command line.
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--columns|--cols)
            cols="$2"
            shift 2
            ;;
        -r|--rows|-l|--lines)
            rows="$2"
            shift 2
            ;;
        -s|--scale)
            scale="$2"
            shift 2
            ;;
        -h|--help)
            echo "$short_help"
            exit 0
            ;;
        -m|--upload-method|--uploading-method)
            uploading_method="$2"
            shift 2
            ;;
        --cell-size)
            cell_size="$2"
            shift 2
            ;;
        --max-cols)
            max_cols="$2"
            shift 2
            ;;
        --max-rows)
            max_rows="$2"
            shift 2
            ;;
        --speed)
            speed="$2"
            shift 2
            ;;
        --)
            file="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -n "$file" ]; then
                echo "Multiple image files are not supported: $file and $1" >&2
                exit 1
            fi
            file="$1"
            shift
            ;;
    esac
done

file="$(realpath "$file")"

#####################################################################
# Adjust the terminal state
#####################################################################

stty_orig="$(stty -g < "$tty")"
stty -echo < "$tty"
# Disable ctrl-z. Pressing ctrl-z during image uploading may cause some
# horrible issues otherwise.
stty susp undef < "$tty"
stty -icanon < "$tty"

restore_echo() {
    [ -n "$stty_orig" ] || return
    stty $stty_orig < "$tty"
}

trap restore_echo EXIT TERM

#####################################################################
# Detect imagemagick
#####################################################################

# If there is the 'magick' command, use it instead of separate 'convert' and
# 'identify' commands.
if command -v magick > /dev/null; then
    identify="magick identify"
    convert="magick"
else
    identify="identify"
    convert="convert"
fi

#####################################################################
# Detect tmux
#####################################################################

# Check if we are inside tmux.
inside_tmux=""
if [ -n "$TMUX" ]; then
    case "$TERM" in
        *tmux*|*screen*)
            inside_tmux=1
            ;;
    esac
fi

#####################################################################
# Compute the number of rows and columns
#####################################################################

is_pos_int() {
    if [ -z "$1" ]; then
        return 1 # false
    fi
    if [ -z "$(printf '%s' "$1" | tr -d '[:digit:]')" ]; then
        if [ "$1" -gt 0 ]; then
            return 0 # true
        fi
    fi
    return 1 # false
}

if [ -n "$cols" ] || [ -n "$rows" ]; then
    if [ -n "$max_cols" ] || [ -n "$max_rows" ]; then
        echo "You can't specify both max-cols/rows and cols/rows" >&2
        exit 1
    fi
fi

# Get the max number of cols and rows.
[ -n "$max_cols" ] || max_cols="$(tput cols)"
[ -n "$max_rows" ] || max_rows="$(tput lines)"
if [ "$max_rows" -gt 255 ]; then
    max_rows=255
fi

python_ioctl_command="import array, fcntl, termios
buf = array.array('H', [0, 0, 0, 0])
fcntl.ioctl(0, termios.TIOCGWINSZ, buf)
print(int(buf[2]/buf[1]), int(buf[3]/buf[0]))"

# Get the cell size in pixels if either cols or rows are not specified.
if [ -z "$cols" ] || [ -z "$rows" ]; then
    cell_width=""
    cell_height=""
    # If the cell size is specified, use it.
    if [ -n "$cell_size" ]; then
        cell_width="${cell_size%x*}"
        cell_height="${cell_size#*x}"
        if ! is_pos_int "$cell_height" || ! is_pos_int "$cell_width"; then
            echo "Invalid cell size: $cell_size" >&2
            exit 1
        fi
    fi
    # Otherwise try to use TIOCGWINSZ ioctl via python.
    if [ -z "$cell_width" ] || [ -z "$cell_height" ]; then
        cell_size_ioctl="$(python3 -c "$python_ioctl_command" < "$tty" 2> /dev/null)"
        cell_width="${cell_size_ioctl% *}"
        cell_height="${cell_size_ioctl#* }"
        if ! is_pos_int "$cell_height" || ! is_pos_int "$cell_width"; then
            cell_width=""
            cell_height=""
        fi
    fi
    # If it didn't work, try to use csi XTWINOPS.
    if [ -z "$cell_width" ] || [ -z "$cell_height" ]; then
        if [ -n "$inside_tmux" ]; then
            printf '\ePtmux;\e\e[16t\e\\' >> "$tty"
        else
            printf '\e[16t' >> "$tty"
        fi
        # The expected response will look like ^[[6;<height>;<width>t
        term_response=""
        while true; do
            char=$(dd bs=1 count=1 <"$tty" 2>/dev/null)
            if [ "$char" = "t" ]; then
                break
            fi
            term_response="$term_response$char"
        done
        cell_height="$(printf '%s' "$term_response" | cut -d ';' -f 2)"
        cell_width="$(printf '%s' "$term_response" | cut -d ';' -f 3)"
        if ! is_pos_int "$cell_height" || ! is_pos_int "$cell_width"; then
            cell_width=8
            cell_height=16
        fi
    fi
fi

# Compute a formula with bc and round to the nearest integer.
bc_round() {
    LC_NUMERIC=C printf '%.0f' "$(printf '%s\n' "scale=2;($1) + 0.5" | bc)"
}

# Compute the number of rows and columns of the image.
if [ -z "$cols" ] || [ -z "$rows" ]; then
    # Get the size of the image and its resolution. If it's an animation, use
    # the first frame.
    format_output="$($identify -format '%w %h\n' "$file" | head -1)"
    img_width="$(printf '%s' "$format_output" | cut -d ' ' -f 1)"
    img_height="$(printf '%s' "$format_output" | cut -d ' ' -f 2)"
    if ! is_pos_int "$img_width" || ! is_pos_int "$img_height"; then
        echo "Couldn't get image size from identify: $format_output" >&2
        echo >&2
        exit 1
    fi
    opt_cols_expr="(${scale}*${img_width}/${cell_width})"
    opt_rows_expr="(${scale}*${img_height}/${cell_height})"
    if [ -z "$cols" ] && [ -z "$rows" ]; then
        # If columns and rows are not specified, compute the optimal values
        # using the information about rows and columns per inch.
        cols="$(bc_round "$opt_cols_expr")"
        rows="$(bc_round "$opt_rows_expr")"
        # Make sure that automatically computed rows and columns are within some
        # sane limits
        if [ "$cols" -gt "$max_cols" ]; then
            rows="$(bc_round "$rows * $max_cols / $cols")"
            cols="$max_cols"
        fi
        if [ "$rows" -gt "$max_rows" ]; then
            cols="$(bc_round "$cols * $max_rows / $rows")"
            rows="$max_rows"
        fi
    elif [ -z "$cols" ]; then
        # If only one dimension is specified, compute the other one to match the
        # aspect ratio as close as possible.
        cols="$(bc_round "${opt_cols_expr}*${rows}/${opt_rows_expr}")"
    elif [ -z "$rows" ]; then
        rows="$(bc_round "${opt_rows_expr}*${cols}/${opt_cols_expr}")"
    fi

    if [ "$cols" -lt 1 ]; then
        cols=1
    fi
    if [ "$rows" -lt 1 ]; then
        rows=1
    fi
fi

#####################################################################
# Generate an image id
#####################################################################

image_id=""
while [ -z "$image_id" ]; do
    image_id="$(shuf -i 16777217-4294967295 -n 1)"
    # Check that the id requires 24-bit fg colors.
    if [ "$(expr \( "$image_id" / 256 \) % 65536)" -eq 0 ]; then
        image_id=""
    fi
done

#####################################################################
# Uploading the image
#####################################################################

# Choose the uploading method
if [ "$uploading_method" = "auto" ]; then
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ] || [ -n "$SSH_CONNECTION" ]; then
        uploading_method="direct"
    else
        uploading_method="file"
    fi
fi

# Functions to emit the start and the end of a graphics command.
if [ -n "$inside_tmux" ]; then
    # If we are in tmux we have to wrap the command in Ptmux.
    graphics_command_start='\ePtmux;\e\e_G'
    graphics_command_end='\e\e\\\e\\'
else
    graphics_command_start='\e_G'
    graphics_command_end='\e\\'
fi

start_gr_command() {
    printf "$graphics_command_start" >> "$tty"
}
end_gr_command() {
    printf "$graphics_command_end" >> "$tty"
}

# Send a graphics command with the correct start and end
gr_command() {
    start_gr_command
    printf '%s' "$1" >> "$tty"
    end_gr_command
}

# Send an uploading command. Usage: gr_upload <action> <command> <file>
# Where <action> is a part of command that specifies the action, it will be
# repeated for every chunk (if the method is direct), and <command> is the rest
# of the command that specifies the image parameters. <action> and <command>
# must not include the transmission method or ';'.
# Example:
# gr_upload "a=T,q=2" "U=1,i=${image_id},f=100,c=${cols},r=${rows}" "$file"
gr_upload() {
    arg_action="$1"
    arg_command="$2"
    arg_file="$3"
    if [ "$uploading_method" = "file" ]; then
        # base64-encode the filename
        encoded_filename=$(printf '%s' "$arg_file" | base64 -w0)
        gr_command "${arg_action},${arg_command},t=f;${encoded_filename}"
    fi
    if [ "$uploading_method" = "direct" ]; then
        # Create a temporary directory to store the chunked image.
        chunkdir="$(mktemp -d)"
        if [ ! "$chunkdir" ] || [ ! -d "$chunkdir" ]; then
            echo "Can't create a temp dir" >&2
            exit 1
        fi
        # base64-encode the file and split it into chunks. The size of each
        # graphics command shouldn't be more than 4096, so we set the size of an
        # encoded chunk to be 3968, slightly less than that.
        chunk_size=3968
        cat "$arg_file" | base64 -w0 | split -b "$chunk_size" - "$chunkdir/chunk_"

        # Issue a command indicating that we want to start data transmission for
        # a new image.
        gr_command "${arg_action},${arg_command},t=d,m=1"

        # Transmit chunks.
        for chunk in "$chunkdir/chunk_"*; do
            start_gr_command
            printf '%s' "${arg_action},i=${image_id},m=1;" >> "$tty"
            cat "$chunk" >> "$tty"
            end_gr_command
            rm "$chunk"
        done

        # Tell the terminal that we are done.
        gr_command "${arg_action},i=$image_id,m=0"

        # Remove the temporary directory.
        rmdir "$chunkdir"
    fi
}

delayed_frame_dir_cleanup() {
    arg_frame_dir="$1"
    sleep 2
    if [ -n "$arg_frame_dir" ]; then
        for frame in "$arg_frame_dir"/frame_*.png; do
            rm "$frame"
        done
        rmdir "$arg_frame_dir"
    fi
}

upload_image_and_print_placeholder() {
    # Check if the file is an animation.
    frame_count=$($identify -format '%n\n' "$file" | head -n 1)
    if [ "$frame_count" -gt 1 ]; then
        # The file is an animation, decompose into frames and upload each frame.
        frame_dir="$(mktemp -d)"
        frame_dir="$HOME/temp/frames${frame_dir}"
        mkdir -p "$frame_dir"
        if [ ! "$frame_dir" ] || [ ! -d "$frame_dir" ]; then
            echo "Can't create a temp dir for frames" >&2
            exit 1
        fi

        # Decompose the animation into separate frames.
        $convert "$file" -coalesce "$frame_dir/frame_%06d.png"

        # Get all frame delays at once, in centiseconds, as a space-separated
        # string.
        delays=$($identify -format "%T " "$file")

        frame_number=1
        for frame in "$frame_dir"/frame_*.png; do
            # Read the delay for the current frame and convert it from
            # centiseconds to milliseconds.
            delay=$(printf '%s' "$delays" | cut -d ' ' -f "$frame_number")
            delay=$((delay * 10))
            # If the delay is 0, set it to 100ms.
            if [ "$delay" -eq 0 ]; then
                delay=100
            fi

            if [ -n "$speed" ]; then
                delay=$(bc_round "$delay / $speed")
            fi

            if [ "$frame_number" -eq 1 ]; then
                # Upload the first frame with a=T
                gr_upload "q=2,a=T" "f=100,U=1,i=${image_id},c=${cols},r=${rows}" "$frame"
                # Set the delay for the first frame and also play the animation
                # in loading mode (s=2).
                gr_command "a=a,v=1,s=2,r=${frame_number},z=${delay},i=${image_id}"
                # Print the placeholder after the first frame to reduce the wait
                # time.
                print_placeholder
            else
                # Upload subsequent frames with a=f
                gr_upload "q=2,a=f" "f=100,i=${image_id},z=${delay}" "$frame"
            fi

            frame_number=$((frame_number + 1))
        done

        # Play the animation in loop mode (s=3).
        gr_command "a=a,v=1,s=3,i=${image_id}"

        # Remove the temporary directory, but do it in the background with a
        # delay to avoid removing files before they are loaded by the terminal.
        delayed_frame_dir_cleanup "$frame_dir" 2> /dev/null &
    else
        # The file is not an animation, upload it directly
        gr_upload "q=2,a=T" "U=1,i=${image_id},f=100,c=${cols},r=${rows}" "$file"
        # Print the placeholder
        print_placeholder
    fi
}

#####################################################################
# Printing the image placeholder
#####################################################################

print_placeholder() {
    # Each line starts with the escape sequence to set the foreground color to
    # the image id.
    blue="$(expr "$image_id" % 256 )"
    green="$(expr \( "$image_id" / 256 \) % 256 )"
    red="$(expr \( "$image_id" / 65536 \) % 256 )"
    line_start="$(printf "\e[38;2;%d;%d;%dm" "$red" "$green" "$blue")"
    line_end="$(printf "\e[39;m")"

    id4th="$(expr \( "$image_id" / 16777216 \) % 256 )"
    eval "id_diacritic=\$d${id4th}"

    # Reset the brush state, mostly to reset the underline color.
    printf "\e[0m"

    # Fill the output with characters representing the image
    for y in $(seq 0 "$(expr "$rows" - 1)"); do
        eval "row_diacritic=\$d${y}"
        printf '%s' "$line_start"
        for x in $(seq 0 "$(expr "$cols" - 1)"); do
            eval "col_diacritic=\$d${x}"
            # Note that when $x is out of bounds, the column diacritic will
            # be empty, meaning that the column should be guessed by the
            # terminal.
            if [ "$x" -ge "$num_diacritics" ]; then
                printf '%s' "${placeholder}${row_diacritic}"
            else
                printf '%s' "${placeholder}${row_diacritic}${col_diacritic}${id_diacritic}"
            fi
        done
        printf '%s\n' "$line_end"
    done

    printf "\e[0m"
}

d0="Ì…"
d1="Ì"
d2="ÌŽ"
d3="Ì"
d4="Ì’"
d5="Ì½"
d6="Ì¾"
d7="Ì¿"
d8="Í†"
d9="ÍŠ"
d10="Í‹"
d11="ÍŒ"
d12="Í"
d13="Í‘"
d14="Í’"
d15="Í—"
d16="Í›"
d17="Í£"
d18="Í¤"
d19="Í¥"
d20="Í¦"
d21="Í§"
d22="Í¨"
d23="Í©"
d24="Íª"
d25="Í«"
d26="Í¬"
d27="Í­"
d28="Í®"
d29="Í¯"
d30="Òƒ"
d31="Ò„"
d32="Ò…"
d33="Ò†"
d34="Ò‡"
d35="Ö’"
d36="Ö“"
d37="Ö”"
d38="Ö•"
d39="Ö—"
d40="Ö˜"
d41="Ö™"
d42="Öœ"
d43="Ö"
d44="Öž"
d45="ÖŸ"
d46="Ö "
d47="Ö¡"
d48="Ö¨"
d49="Ö©"
d50="Ö«"
d51="Ö¬"
d52="Ö¯"
d53="×„"
d54="Ø"
d55="Ø‘"
d56="Ø’"
d57="Ø“"
d58="Ø”"
d59="Ø•"
d60="Ø–"
d61="Ø—"
d62="Ù—"
d63="Ù˜"
d64="Ù™"
d65="Ùš"
d66="Ù›"
d67="Ù"
d68="Ùž"
d69="Û–"
d70="Û—"
d71="Û˜"
d72="Û™"
d73="Ûš"
d74="Û›"
d75="Ûœ"
d76="ÛŸ"
d77="Û "
d78="Û¡"
d79="Û¢"
d80="Û¤"
d81="Û§"
d82="Û¨"
d83="Û«"
d84="Û¬"
d85="Ü°"
d86="Ü²"
d87="Ü³"
d88="Üµ"
d89="Ü¶"
d90="Üº"
d91="Ü½"
d92="Ü¿"
d93="Ý€"
d94="Ý"
d95="Ýƒ"
d96="Ý…"
d97="Ý‡"
d98="Ý‰"
d99="ÝŠ"
d100="ß«"
d101="ß¬"
d102="ß­"
d103="ß®"
d104="ß¯"
d105="ß°"
d106="ß±"
d107="ß³"
d108="à –"
d109="à —"
d110="à ˜"
d111="à ™"
d112="à ›"
d113="à œ"
d114="à "
d115="à ž"
d116="à Ÿ"
d117="à  "
d118="à ¡"
d119="à ¢"
d120="à £"
d121="à ¥"
d122="à ¦"
d123="à §"
d124="à ©"
d125="à ª"
d126="à «"
d127="à ¬"
d128="à ­"
d129="à¥‘"
d130="à¥“"
d131="à¥”"
d132="à¾‚"
d133="à¾ƒ"
d134="à¾†"
d135="à¾‡"
d136="á"
d137="áž"
d138="áŸ"
d139="áŸ"
d140="á¤º"
d141="á¨—"
d142="á©µ"
d143="á©¶"
d144="á©·"
d145="á©¸"
d146="á©¹"
d147="á©º"
d148="á©»"
d149="á©¼"
d150="á­«"
d151="á­­"
d152="á­®"
d153="á­¯"
d154="á­°"
d155="á­±"
d156="á­²"
d157="á­³"
d158="á³"
d159="á³‘"
d160="á³’"
d161="á³š"
d162="á³›"
d163="á³ "
d164="á·€"
d165="á·"
d166="á·ƒ"
d167="á·„"
d168="á·…"
d169="á·†"
d170="á·‡"
d171="á·ˆ"
d172="á·‰"
d173="á·‹"
d174="á·Œ"
d175="á·‘"
d176="á·’"
d177="á·“"
d178="á·”"
d179="á·•"
d180="á·–"
d181="á·—"
d182="á·˜"
d183="á·™"
d184="á·š"
d185="á·›"
d186="á·œ"
d187="á·"
d188="á·ž"
d189="á·Ÿ"
d190="á· "
d191="á·¡"
d192="á·¢"
d193="á·£"
d194="á·¤"
d195="á·¥"
d196="á·¦"
d197="á·¾"
d198="âƒ"
d199="âƒ‘"
d200="âƒ”"
d201="âƒ•"
d202="âƒ–"
d203="âƒ—"
d204="âƒ›"
d205="âƒœ"
d206="âƒ¡"
d207="âƒ§"
d208="âƒ©"
d209="âƒ°"
d210="â³¯"
d211="â³°"
d212="â³±"
d213="â· "
d214="â·¡"
d215="â·¢"
d216="â·£"
d217="â·¤"
d218="â·¥"
d219="â·¦"
d220="â·§"
d221="â·¨"
d222="â·©"
d223="â·ª"
d224="â·«"
d225="â·¬"
d226="â·­"
d227="â·®"
d228="â·¯"
d229="â·°"
d230="â·±"
d231="â·²"
d232="â·³"
d233="â·´"
d234="â·µ"
d235="â·¶"
d236="â··"
d237="â·¸"
d238="â·¹"
d239="â·º"
d240="â·»"
d241="â·¼"
d242="â·½"
d243="â·¾"
d244="â·¿"
d245="ê™¯"
d246="ê™¼"
d247="ê™½"
d248="ê›°"
d249="ê›±"
d250="ê£ "
d251="ê£¡"
d252="ê£¢"
d253="ê££"
d254="ê£¤"
d255="ê£¥"
d256="ê£¦"
d257="ê£§"
d258="ê£¨"
d259="ê£©"
d260="ê£ª"
d261="ê£«"
d262="ê£¬"
d263="ê£­"
d264="ê£®"
d265="ê£¯"
d266="ê£°"
d267="ê£±"
d268="êª°"
d269="êª²"
d270="êª³"
d271="êª·"
d272="êª¸"
d273="êª¾"
d274="êª¿"
d275="ê«"
d276="ï¸ "
d277="ï¸¡"
d278="ï¸¢"
d279="ï¸£"
d280="ï¸¤"
d281="ï¸¥"
d282="ï¸¦"
d283="ð¨"
d284="ð¨¸"
d285="ð†…"
d286="ð††"
d287="ð†‡"
d288="ð†ˆ"
d289="ð†‰"
d290="ð†ª"
d291="ð†«"
d292="ð†¬"
d293="ð†­"
d294="ð‰‚"
d295="ð‰ƒ"
d296="ð‰„"

num_diacritics="297"

placeholder="ôŽ»®"

#####################################################################
# Upload the image and print the placeholder
#####################################################################

upload_image_and_print_placeholder
