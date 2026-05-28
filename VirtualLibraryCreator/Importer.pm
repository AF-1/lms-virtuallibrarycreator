#
# Virtual Library Creator
# (c) 2023 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::VirtualLibraryCreator::Importer;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;
use Plugins::VirtualLibraryCreator::Common ':all';

my $prefs = preferences('plugin.virtuallibrarycreator');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.virtuallibrarycreator');

sub initPlugin {
	main::DEBUGLOG && $log->is_debug && $log->debug('Importer module init');
	Slim::Music::Import->addImporter('Plugins::VirtualLibraryCreator::Importer', {
		'type' => 'post',
		'weight' => 1999,
		'use' => 1,
	});
}

sub startScan {
	my $class = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('Starting VLC post-scan VL init');
	$class->initVirtualLibraries();
	Slim::Music::Import->endImporter($class);
}

1;
