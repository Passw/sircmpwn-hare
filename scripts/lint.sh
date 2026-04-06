#!/bin/sh -eu

find . -name '*.ha' ! -path ./hare/parse/doc/+test.ha | while read -r f; do
	awk 'BEGIN { state = "start" }
		/./ { empty = 0 }
		/^$/ { empty = 1 }
		/[ \t]$/ {
			print "trailing whitespace in " FILENAME
			exit 1
		}
		/^(\t* \t| )/ {
			print "spaces used for indentation in " FILENAME
			exit 1
		}
		state == "start" {
			if ($0 !~ /^\/\/ SPDX-License-Identifier: /) {
				print "missing copyright header in " FILENAME
				exit 1
			}
			state = "author"
			next
		}
		state == "author" {
			if ($0 != "// (c) Hare authors <https://harelang.org>") {
				print "invalid authorship information in " FILENAME
				exit 1
			}
			state = "comment"
			next
		}
		state == "comment" && $0 !~ /^\/\// {
			if ($0 != "") {
				print "missing empty line after copyright header in " FILENAME
				exit 1
			}
			state = "postheader"
			next
		}
		state == "postheader" {
			if ($0 == "") {
				print "extra empty line after copyright header in " FILENAME
				exit 1
			}
			state = "body"
		}
		END {
			if (state != "body") {
				print "incomplete copyright header in " FILENAME
				exit 1
			}
			if (empty) {
				print "trailing empty line in " FILENAME
				exit 1
			}
		}' "$f"
done
