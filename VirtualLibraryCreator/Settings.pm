#
# Virtual Library Creator
#
# (c) 2023 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
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
	return ($prefs, qw(customdirparentfolderpath exacttitlesearch browsemenus_parentfoldername browsemenus_parentfoldericon dailyvlrefreshtime displayvlids displayhasbrowsemenus displayisdailyrefreshed));
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
	if ($paramRef->{'manualvlrecreatenow'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::VirtualLibraryCreator::Plugin::manualVLrefresh();
	} elsif ($paramRef->{'refreshcachesnow'}) {
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
