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
use Slim::Utils::Prefs;

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

1;
