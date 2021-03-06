#!/usr/bin/perl
# This generates the "unusable free space index" based on buddyinfo-like output
# and the fragmentation index in the event a requested allocation would fail.
# This metric for external fragmentation measures how much of the available free
# memory can be used to satisfy an allocation of a given size
#
# License under the LGPL 2.1
# (c) Mel Gorman 2002
my $p = "pagealloc-extfrag";
use FindBin qw($Bin);
use lib "$Bin/lib";

use POSIX;
use Pod::Usage;
use Getopt::Long;
# use FA::Report;
use strict;

# Option variables
my $opt_infile = "--###--";
my $opt_help = 0;
my $opt_man = 0;
my $opt_verbose;
my $opt_zone = "All";
my $opt_node = "All";
my $opt_order = -1;
my $opt_delay = -1;
my $opt_addsuccess = 0;
my $opt_ignoreavailable;
my $opt_all;
my $opt_includefail = 0;
my $pagesize = POSIX::sysconf(POSIX::_SC_PAGESIZE);

# Get options
GetOptions(
        'help|h'     => \$opt_help,
	'man|m'      => \$opt_man,
        'infile|i=s' => \$opt_infile,
        'zone|z=s'   => \$opt_zone,
	'node=s'     => \$opt_node,
        'order|s=s'  => \$opt_order,
	'all|a'      => \$opt_all,
	'delay|n=n'  => \$opt_delay,
	'add-successful=n' => \$opt_addsuccess,
	'ignore-available' => \$opt_ignoreavailable,
        'verbose|v'  => \$opt_verbose,
        );
# Print usage if requested
pod2usage(-exitstatus => 0, -verbose => 0) if $opt_help;
pod2usage(-exitstatus => 0, -verbose => 2) if $opt_man;
$opt_verbose && setVerbose();

# Default the infile
if ($opt_infile eq "--###--") {
	if (-p STDIN) {
		$opt_infile = "-";
	} else {
		$opt_infile = "/proc/buddyinfo";
	}
	print("$p\::Setting default for input file: $opt_infile\n");
}

# Make sure the input file looks ok
if ($opt_infile ne "-" && ! -e $opt_infile) {
	die("$opt_infile does not exist\n");
}

# Default the order
if ($opt_order == -1) {
	my $line;
	my $hugepagesize = 0;
	open MEMINFO, "/proc/meminfo" || die("Failed to open /proc/meminfo: $!");

	while (!eof(MEMINFO)) {
		$line = <MEMINFO>;
		if ($line =~ /^Hugepagesize:\s+([0-9]+) kB/) {
			$hugepagesize = $1 * 1024;
		}
	}
	close MEMINFO;
	if ($hugepagesize == 0) {
		print "Failed to detect hugepage size, defaulting to order 10\n";
		$opt_order = 10;
	} else {
		my $basepages = $hugepagesize / $pagesize;
		$opt_order = log($basepages) / log(2);
		print("$p\::pagesizes: base $pagesize huge $hugepagesize\n");
		print("$p\::Setting default order: $opt_order\n");
	}
}

do {

# Open the file
print("$p\::Processing $opt_infile\n");
if ($opt_infile ne "-") {
	print("$p\::Opening $opt_infile\n");
	open(BUDDYINFO, $opt_infile) || die("Failed to open $opt_infile: $!");
}

# Initialise the fields used to make the index calculation
my $totalFree = 0;
my $totalBlocks = 0;
my $totalHighBlocks = 0;
my $totalExpected = 0;
my $totalHigh = 0;
my $sizeRequested = 2 ** $opt_order;
my $blankLines = 0;

# Process the file
while (($opt_infile ne '-' && !eof(BUDDYINFO)) || ($opt_infile eq '-' && !eof(STDIN))) {
	my $line;
	if ($opt_infile eq "-" ) {
		$line = <STDIN>;
	} else {
		$line = <BUDDYINFO>;
	}
	print("$p\::Read $line");

	# Skip the line if the node or zone do not match what we need
	if ($line =~ /^Node ([0-9]), zone\s*([a-zA-Z0-9]*)/) {
		if ($opt_node ne $1 && $opt_node ne "All") {
			print("Skipping node $1\n");
			next;
		}
  		if ($opt_zone ne $2 && $opt_zone ne "All") {
      			print("Skipping zone $2\n");
			next;
		}
	}

	my @info = split(/\s+/, $line);
	for (my $i=4; $i <= $#info; $i++) {
		my $blocks = $info[$i];
		my $order = $i-4;
		my $pages = $blocks * (2 ** $order);

		$totalBlocks += $blocks;
		$totalFree += $pages;

		if ($order >= $opt_order && !$opt_ignoreavailable) {
			$totalHigh += $pages;
			$totalHighBlocks += $blocks;
			$totalExpected += $blocks * (2 ** ($order - $opt_order));
		}

	}
}
close BUDDYINFO;

# Add an assumed success count of huge pages is specified
if ($opt_addsuccess != 0) {
	$totalBlocks += $opt_addsuccess;
	$totalFree += $opt_addsuccess * (2 ** $opt_order);
	$totalHigh += $opt_addsuccess * (2 ** $opt_order);
	$totalHighBlocks += $opt_addsuccess;
	$totalExpected += $opt_addsuccess;
}

my $unusable_index;
my $fragmentation_index;
if ($totalFree == 0) {
	$unusable_index = 1;
} else {
	$unusable_index = (($totalFree - $totalHigh) / $totalFree);
}
if ($unusable_index == 1) {
	if ($totalFree < $sizeRequested) {
		$fragmentation_index = 0;
	} else {
		$fragmentation_index = 1 - ( (1+($totalFree / $sizeRequested)) / $totalBlocks);
	}
}
if (!$opt_all) {
	print "unusable_freespace_index: $unusable_index";
	if ($unusable_index == 1) {
		print " fragmentation_index: $fragmentation_index";
	}
	print "\n";
} else {
	print "Total base pages free:                      $totalFree\n";
	print "Total blocks free:                          $totalBlocks\n";
	print "Total suitable high-order blocks:           $totalHighBlocks\n";
	print "Total suitable base pages free:             $totalHigh\n";
	print "Requested allocation size:                  $sizeRequested\n";
	print "Expected successful high-order allocations: $totalExpected\n";
	print "Unusable free space index:                  $unusable_index\n";
	if ($unusable_index == 1) {
		print "Fragmentation index:                        $fragmentation_index\n";
	}
}

if ($opt_delay > 0) {
	sleep($opt_delay);
}

} while ($opt_delay > 0);

# Below this line is help and manual page information
__END__

=head1 NAME

pagealloc-extfrag - Measure the extent of external fragmentation from a buddyinfo report

=head1 SYNOPSIS

pagealloc-extfrag [options]

 Options:
    --help         Print help messages
    --man          Print man page
    -i, --infile   Read this input file, use - for standard in
    -z, --zone     Only calculate external fragmentation in this zone
    -n, --node     Only calculate external fragmentation in this node
    -o, --order    Calculate external fragmentation based on a given
                   power-of-two allocation size. Default: hugepage size
    -a, --all      Print out all information gathered
    -v, --verbose  Print some debugging output
    -n, --delay    Print a report every n seconds

=head1 DESCRIPTION

External fragmentation refers to the inability to satisfy an allocation
because a suitably large contiguous block of memory is not free even
though enough memory may be free overall. This tool measures the extent of
fragmentation using two metrics.

Unusable free space index measures how much of the available free memory can
be used to satisfy an allocation of a given size. A value tending towards
0 indicates low fragmentation and a value tending towards 1 indicates high
fragmentation.

On allocation failure, the Unusable free space index will be 1 so the
Fragmentation index is calculated. A fragmentation index tending towards
0 implies the allocation failed due to lack of memory. A fragmentation
index tending towards 1 implies the allocation failed due to high external
fragmentation.

Both metrics take into account the size of the allocation been made which
can be specified with B<-o>. A default size is chosen based on the default
huge page size configured in the system.

=head1 OPTIONS

=over 8

=item B<--help>

Print a help message and exit

=item B<-a, --all>

By default, just the unusable free space index and fragmentation index
are displayed.  This option will print a much larger amount of information.

=item B<-i, --infile>

Use this file as an input file instead of STDIN or /proc/buddyinfo.

=item B<-z, --zone>

By default, all zones in the system are taken into account. This allows
the calculation to be made on a specific zone.

=item B<-n, --node>

By default, all nodes in the system are taken into account. This allows
the calculation to be made on a specific node.

=item B<-o, --order>

The page allocator grants contiguous pages in units of powers-of-two called
the order. By default, the order chosen is that which is necessary to allocate
the default hugepage size. This option allows an alternative order to be used.

=item B<-n, --delay>

By default, a single report is generated and the program exits. This option
will generate a report every requested number of seconds. It only makes
sense when the input file is a named pipe or /proc/buddyinfo.

=back

=head1 AUTHOR

Written by Mel Gorman (mel@csn.ul.ie)

=head1 REPORTING BUGS

Report bugs to the author

=cut
