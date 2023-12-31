#
# Virtual Library Creator
#
# (c) 2023 AF
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

package Plugins::VirtualLibraryCreator::ConfigManager::TemplateContentParser;

use strict;
use warnings;
use utf8;

use base qw(Slim::Utils::Accessor);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use File::Spec::Functions qw(:ALL);
use File::Slurp;
use FindBin qw($Bin);

use Plugins::VirtualLibraryCreator::ConfigManager::BaseParser;
our @ISA = qw(Plugins::VirtualLibraryCreator::ConfigManager::BaseParser);

__PACKAGE__->mk_accessor(rw => qw(templatePluginHandler));

my $log = logger('plugin.virtuallibrarycreator');
my $prefs = preferences('plugin.virtuallibrarycreator');

sub new {
	my ($class, $parameters) = @_;

	$parameters->{'contentType'} = 'virtuallibrary';
	my $self = $class->SUPER::new($parameters);
	$self->templatePluginHandler($parameters->{'templatePluginHandler'});

	return $self;
}

sub loadTemplate {
	my ($self, $client, $template, $parameters) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("Searching for template: ".$template->{'id'});
	my $templateFileData = undef;
	my $doParsing = 1;
	my $templateFile = $template->{'id'};
	$templateFile =~ s/\.sql\.xml$/.sql.template/;
	my $path = undef;
	my @pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');

	for my $plugindir (@pluginDirs) {
		if (-d catdir($plugindir, "VirtualLibraryCreator", "Templates")) {
			$path = catfile($plugindir, "VirtualLibraryCreator", "Templates", $templateFile);
		}
	}
	if (defined($path)) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Reading template: $templateFile");
		$templateFileData = eval { read_file($path) };
		if ($@) {
			$log->error("Unable to open file: $path because of: $@");
		} else {
			my $encoding = Slim::Utils::Unicode::encodingFromString($templateFileData);
			if ($encoding ne 'utf8') {
				$templateFileData = Slim::Utils::Unicode::latin1toUTF8($templateFileData);
				$templateFileData = Slim::Utils::Unicode::utf8on($templateFileData);
				main::DEBUGLOG && $log->is_debug && $log->debug("Loading $templateFile and converting from latin1");
			} else {
				$templateFileData = Slim::Utils::Unicode::utf8decode($templateFileData, 'utf8');
				main::DEBUGLOG && $log->is_debug && $log->debug("Loading $templateFile without conversion with encoding ".$encoding);
			}
		}
	}

	if (!defined($templateFileData)) {
		return undef;
	}
	my %result = (
		'data' => \$templateFileData,
		'parse' => $doParsing
	);
	return \%result;
}

sub parse {
	my ($self, $client, $item, $content, $items, $globalcontext, $localcontext) = @_;
	return $self->parseTemplateContent($client, $item, $content, $items, $globalcontext->{'templates'}, $globalcontext, $localcontext);
}

1;
