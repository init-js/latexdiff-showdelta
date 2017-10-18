#!/bin/bash -e
set -o pipefail

#
# Produce output file showing LaTeX differences between two revisions
# of a latex document's repository. Additions in blue, deletions in
# red. If the two versions are very different (structural changes in
# macros, file renames, etc) this script may limp a bit.
#
# Place this script in the root directory of a latex repository.
#

function usage ()
{
    echo "
   Usage: $(basename "$0") [OPT]* REV

        REV     is the 'from' revision

   OPT may be of:

         -h --help      This text

         --cmd    CMD   Command to build the output [make]

         --to     REV2  The 'to' revision. [tip]

         --target TGT   Name of the output file produced by
                        the paper's build command, relative to
                        the root of the repo. [Inferred from the
                        TARGET variable in the local makefile.]

         -o --output FILE The name of the final diff document.
                          [./delta.REV1.REV2n.pdf]
"
}

function cleanup ()
{
    if [[ -d "$T" ]]; then
	rm -rf --one-file-system "$T" || :
    fi
}

function no_ext ()
{
    local f="$1"
    local ext="${f##*.}"
    if [[ "$ext" == "$f" ]]; then
	echo "$f"
    fi
    echo "${f%.*}"
}

# prints the location of the .git folder
# errors out if not in a git repo
function git_dir ()
{
    if [[ -d .git ]]; then
	echo .git;
    else
	git rev-parse --git-dir 2> /dev/null
    fi
}

function infer_target ()
{
    if [[ ! -f "$HERE"/Makefile ]]; then
	echo "No makefile found" >&2
	return 1
    fi

    local target="$(egrep "^TARGET=" Makefile | head -n 1)"
    if [[ -z "$target" ]]; then
	echo "No variable TARGET= found in makefile" >&2
	return 1;
    fi

    target="${target#*=}"
    if [[ -z "$target" ]]; then
	echo "Empty TARGET= found." >&2
	return 1;
    fi

    local ext="${target##*.}"
    if [[ "$ext" == "$target" ]]; then
	ext="pdf"
    fi
    echo "$target.$ext"
}

function confirm ()
{
    while true; do
	read -p "$1 [Y/n] "
	case "$REPLY" in
	    n|N|NO|no|nO|No)
		return 1;
		;;
	    *)
		return 0;
		;;
	esac
    done
}

T=
trap cleanup EXIT ERR

CMD="make"
HERE="$(cd "$(dirname "$0")" && pwd)"
R1=
R2=
OUTPUT=
TARGET=
MAINTEX=
T="$(mktemp -d showdelta.XXXXXXX)"
ARGS=()

LDIFFOPTS=(
    #"-t TRADITIONAL"
    "--config=PICTUREENV=(?:picture|author|DIFnomarkup)[\w\d*@]*"
    "--exclude-textcmd=section,author"
)

if git_dir >/dev/null; then
    R2="HEAD"
else
    R2="tip"
fi


while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
	-h|--help)
	    usage
	    exit 0
	    ;;
	--to)
	    shift
	    R2="$1"
	    ;;
	-o|--output)
	    shift
	    OUTPUT="$1"
	    ;;
	--target)
	    shift
	    TARGET="$1"
	    ;;
	-c|--cmd)
	    shift
	    CMD="$1"
	    ;;
	--)
	    shift
	    ARGS+=( "$@" )
	    ;;
	-*)
	    echo "Invalid argument $1" >&2
	    exit 1
	    ;;
	*)
	    ARGS+=( "$arg" )
	    ;;
    esac
    shift
done

if [[ "${#ARGS[@]}" -lt 1 ]]; then
    echo "missing arguments" >&2
    exit 1
fi

R1="${ARGS[0]}"
[[ -n "$TARGET" ]] || {
    TARGET="$(infer_target)"
    echo "Assuming target: $TARGET" >&2
}
MAIN="$(no_ext "$TARGET").tex"
echo "Main tex file: $MAIN" >&2

EXT="${TARGET##*.}"
echo "Computing delta from revision '$R1' to revision '$R2'." >&2

mkdir "$T/A" "$T/B"

if git_dir >/dev/null; then
    (cd "$HERE" && git archive "$R1" ) | tar -x -C "$T/A"
    (cd "$HERE" && git archive "$R2" ) | tar -x -C "$T/B"
    R2REV="$(git rev-parse --short "$R2")"
else
    hg clone -r "$R1" "$HERE" "$T/A"
    hg clone -r "$R2" "$HERE" "$T/B"
    R2REV="$( cd "$T/B" && echo $(hg id -n) )"
fi


[[ -n "$OUTPUT" ]] || OUTPUT="$HERE/delta.$R1-$R2REV.$EXT"

(
    cd "$T/B"
    while read -u 3 tex; do
	if confirm "Include $tex in the diff?"; then
	    mv "$tex" "$tex.tmp"
	    (
		set -x
		latexdiff "${LDIFFOPTS[@]}" "../A/$tex" "$tex.tmp" > "$tex"
	    )
	fi
    done 3< <(find . -name '*.tex')

    grep "DIF PREAMBLE EXTENSION ADDED BY LATEXDIFF" "$MAIN" -q || {
	# add preamble
	mv "$MAIN" "$MAIN.tmp"
	cat <(latexdiff "${LDIFFOPTS[@]}" --show-preamble |
	    grep -v "Preamble commands:") "$MAIN.tmp" > "$MAIN"
    }

    make || {
	echo "Compiling the document failed. Exit temp shell when fixed." >&2
	bash || :
    }
)

if [[ ! -f "$T/B/$TARGET" ]]; then
    echo "Failed to retrieve target compilation output." >&2
    exit
fi


cp "$T/B/$TARGET" "$OUTPUT"
echo "Output written to: $OUTPUT"

