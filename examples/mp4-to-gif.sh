#!/usr/bin/env bash

script_dir="${BASH_SOURCE[0]%/*}"
[[ "${script_dir}" == "${BASH_SOURCE[0]}" ]] && script_dir="."
[[ -z "${script_dir}" ]] && script_dir="."
cd "${script_dir}" || exit 1

transitions_dir="examples"

if [[ ! -d "${transitions_dir}" ]]; then
	printf 'Error: Directory not found: %s\n' "${transitions_dir}" >&2
	exit 1
fi

shopt -s nullglob
mp4_files=("${transitions_dir}"/*.mp4)
shopt -u nullglob

filtered_files=()
for file in "${mp4_files[@]}"; do
	[[ "${file}" == *-p.mp4 ]] && continue
	filtered_files+=("${file}")
done

total=${#filtered_files[@]}
if ((total == 0)); then
	printf 'No .mp4 files found in %s.\n' "${transitions_dir}"
	exit 0
fi

printf 'Found %d MP4 files to convert in %s.\n' "${total}" "${transitions_dir}"

count=0
fps=15
width=800

for mp4 in "${filtered_files[@]}"; do
	((count++))
	name="${mp4##*/}"
	base_name="${name%.mp4}"
	gif="${transitions_dir}/${base_name}.gif"
	tmp_gif="${transitions_dir}/${base_name}.tmp.gif"

	printf '[%d/%d] Converting %s.mp4 -> %s.gif...\n' "${count}" "${total}" "${base_name}" "${base_name}"

	ffmpeg -hide_banner -loglevel error -stats -y \
		-i "${mp4}" \
		-vf "fps=${fps},scale=${width}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
		-loop 0 \
		"${tmp_gif}"
	status=$?

	if ((status == 0)); then
		mv -f "${tmp_gif}" "${gif}"
	else
		rm -f "${tmp_gif}"
		printf 'Failed to convert %s\n' "${mp4}" >&2
	fi
done

printf 'Done! Converted %d file(s).\n' "${count}"
exit 0
