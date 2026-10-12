#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Convenience wrapper: ./uninstall.sh            -> remove the software only
#                      ./uninstall.sh --purge    -> remove EVERYTHING (config, image, userdata, logs)
exec sudo "$(dirname "$(readlink -f "$0")")/install.sh" "${@:---uninstall}"
