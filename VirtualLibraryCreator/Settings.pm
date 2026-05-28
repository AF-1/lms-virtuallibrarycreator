#
# Virtual Library Creator
# (c) 2023 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::VirtualLibraryCreator::Settings;

use strict;
use warnings;
use utf8;

use base qw(Slim::Web::Settings);

use File::Basename;
use File::Next;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $log = logger('plugin.virtuallibrarycreator');
my $prefs = preferences('plugin.virtuallibrarycreator');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_VIRTUALLIBRARYCREATOR');
}

sub page {
	return 'plugins/VirtualLibraryCreator/settings/settings.html';
}

sub prefs {
	return ($prefs, qw(customdirparentfolderpath exacttitlesearch browsemenus_parentfoldername browsemenus_parentfoldericon dailyvlrefreshtime displayvlids displayhasbrowsemenus displayisdailyrefreshed hidezerotrackvls));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		Plugins::VirtualLibraryCreator::Plugin::getConfigManager()->initWebPageMethods();
		$callHandler = 0;
	}
	if ($paramRef->{'refreshcachesnow'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::VirtualLibraryCreator::Plugin::refreshSQLCache();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}
	return $result;
}

1;
