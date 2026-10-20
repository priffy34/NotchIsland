# Запускается через /usr/bin/perl (системный бинарник Apple) — только так
# на macOS 15.4+ можно читать Now Playing через MediaRemote.
use strict;
use warnings;
use DynaLoader;

my ($lib, $fn) = @ARGV;
my $handle = DynaLoader::dl_load_file($lib, 0)
    or die "cannot load $lib: " . DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($handle, $fn)
    or die "symbol $fn not found";
my $xs = DynaLoader::dl_install_xsub("main::run_adapter", $sym);
&$xs();
exit 0;
