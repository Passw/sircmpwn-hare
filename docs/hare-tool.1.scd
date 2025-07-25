hare-tool(1)

# NAME

hare tool - run third-party Hare tools

# SYNOPSIS

*hare tool* _command_ [_arguments_...]

# DESCRIPTION

*hare tool* executes a third-party Hare tool named _command_ with the given
_arguments_.

Third-party tools are installed in the "libexec" directory that the toolchain
was configured with, which is typically _/usr/libexec/hare_. Each is prefixed
with "hare-", so on a typical configuration, *hare tool example* will run
_/usr/libexec/hare/hare-example_.

# SEE ALSO

*hare*(1)
