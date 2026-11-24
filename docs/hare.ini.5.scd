hare.ini(5)

# NAME

hare.ini - Declared Hare modules

# DESCRIPTION

A declared module manifest is a file used to configure a declared Hare module. A
file named *hare.ini* can be placed at the base directory of a Hare module (so,
for example, _foo::bar_'s manifest is located at _foo/bar/hare.ini_). The
manifest uses the INI file format, with a set of _key=value_ pairs organized
into _[sections]_.

# CONDITIONAL CONFIGURATION

_key=value_ pairs which are located outside of any _[section]_ configure the
default parameters for all build configurations.

A _key=value_ pair located within a _[section]_ is only applicable if the
conditions for that section are met. The _section_ is a set of build tags (e.g.
*+linux+x86_64*, see *hare-module*(5) under BUILD TAGS) which configure whether
or not the _key=value_ pairs in that section are applied to this build.

The special section named _[^]_ is applicable if no other sections have been
matched prior to the point at which it appears.

```
sources = *.ha

[+linux]
sources = linux/*.ha

[^]
sources = generic/*.ha
```

# CONFIGURATION PARAMETERS

The following parameters are recognized by the build driver.

If a parameter appears more than once, it is cumulative (so if *sources* appears
twice, both lists of source files are merged and included in the build).

*dependencies*
	A list of package names to link with during the build. The means by
	which the appropriate flags for a package are defined is
	platform-specific, but in most cases it relies on *pkg-config*(1).

	```
	dependencies = sdl3
	```

*libs*
	A list of libraries to link with during the build, in the form of *-l*
	or *-L* flags only.

	```
	libs = -L/usr/local/lib -lSDL3 -lzlib
	```

	The value is subject to shell expansion (using the system shell, e.g.
	/bin/sh on POSIX systems), allowing for globbing, variable
	substitutions, subcommands, and so on.

*sources*
	A list of source files to include for the build. If this configuration
	parameter is not specified, the sources for the module are collected
	according to the same algorithm used for automatic modules. See
	*hare-module*(5).

	The value is subject to shell expansion (using the system shell, e.g.
	/bin/sh on POSIX systems), allowing for globbing, variable
	substitutions, subcommands, and so on.

*def ident[:type] = value*
	Declares a constant. This constant is visible only to the module to
	which the *hare.ini* file applies. To export it to other users, declare
	it in your Hare code:

	```
	// hare.ini
	def MY_DEF: bool = true
	// example.ha
	export def MY_DEF: bool = false;
	```

	If you don't define MY_DEF in hare.ini, the default value of false
	applies to this example.

	See the -D flag in *hare-build*(1) for more information.

# SEE ALSO

*hare*(1), *hare-module*(5), *hare.ini*(5)
