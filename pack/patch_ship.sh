# 补丁随包判定（补丁包部署方案 v2，满屏补丁线 11-04；pack/stage_rewrite.sh 与 tests/pack_test.sh 共用这一份）：
#   ipa_patch_ship <patch.tsv> <main 构建号> → 0 = 文件头（第一个「[段]」之前）verified_builds（空格分隔，不分大小写）含本构建号 = 这一版真机验过、可随包下发
ipa_patch_ship() { awk -F'\t' -v b="$2" '/^\[/ { exit } $1 == "verified_builds" { n = split($2, v, " "); for (i = 1; i <= n; i++) if (tolower(v[i]) == tolower(b)) f = 1 } END { exit !f }' "$1"; }
