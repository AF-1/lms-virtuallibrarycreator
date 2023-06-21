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

package Plugins::VirtualLibraryCreator::ConfigManager::Main;

use strict;
use warnings;
use utf8;

use base qw(Slim::Utils::Accessor);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::VirtualLibraryCreator::ConfigManager::TemplateParser;
use Plugins::VirtualLibraryCreator::ConfigManager::ContentParser;
use Plugins::VirtualLibraryCreator::ConfigManager::TemplateContentParser;
use Plugins::VirtualLibraryCreator::ConfigManager::DirectoryLoader;
use Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler;
use Plugins::VirtualLibraryCreator::ConfigManager::VLWebPageMethods;
use FindBin qw($Bin);
use File::Spec::Functions qw(:ALL);

__PACKAGE__->mk_accessor(rw => qw(pluginVersion contentDirectoryHandler templateContentDirectoryHandler templateDirectoryHandler templateDataDirectoryHandler contentPluginHandler templatePluginHandler parameterHandler templateParser contentParser templateContentParser webPageMethods addSqlErrorCallback templates items browseMenus));

my $log = logger('plugin.virtuallibrarycreator');
my $prefs = preferences('plugin.virtuallibrarycreator');

sub new {
	my ($class, $parameters) = @_;
	my $self = $class->SUPER::new();

	$self->pluginVersion($parameters->{'pluginVersion'});
	$self->addSqlErrorCallback($parameters->{'addSqlErrorCallback'});
	$self->browseMenus($parameters->{'browseMenus'});
	$self->init();
	return $self;
}

sub init {
	my $self = shift;
	$self->templateParser(Plugins::VirtualLibraryCreator::ConfigManager::TemplateParser->new());

	my %parameters = (
		'criticalErrorCallback' => $self->addSqlErrorCallback,
		'parameterPrefix' => 'itemparameter'
	);
	$self->parameterHandler(Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler->new(\%parameters));
	$self->contentParser(Plugins::VirtualLibraryCreator::ConfigManager::ContentParser->new(\%parameters));

	my %directoryHandlerParameters = (
		'pluginVersion' => $self->pluginVersion,
	);

	$directoryHandlerParameters{'extension'} = "sql";
	$directoryHandlerParameters{'parser'} = $self->contentParser;
	$directoryHandlerParameters{'includeExtensionInIdentifier'} = undef;
	$self->contentDirectoryHandler(Plugins::VirtualLibraryCreator::ConfigManager::DirectoryLoader->new(\%directoryHandlerParameters));

	$directoryHandlerParameters{'extension'} = "sql.xml";
	$directoryHandlerParameters{'identifierExtension'} = "sql.xml";
	$directoryHandlerParameters{'parser'} = $self->templateParser;
	$directoryHandlerParameters{'includeExtensionInIdentifier'} = 1;
	$self->templateDirectoryHandler(Plugins::VirtualLibraryCreator::ConfigManager::DirectoryLoader->new(\%directoryHandlerParameters));

	$directoryHandlerParameters{'extension'} = "sql.template";
	$directoryHandlerParameters{'identifierExtension'} = "sql.xml";
	$directoryHandlerParameters{'parser'} = $self->contentParser;
	$directoryHandlerParameters{'includeExtensionInIdentifier'} = 1;
	$self->templateDataDirectoryHandler(Plugins::VirtualLibraryCreator::ConfigManager::DirectoryLoader->new(\%directoryHandlerParameters));

	$self->templateContentParser(Plugins::VirtualLibraryCreator::ConfigManager::TemplateContentParser->new());

	$directoryHandlerParameters{'extension'} = "customvalues.xml";
	$directoryHandlerParameters{'parser'} = $self->templateContentParser;
	$directoryHandlerParameters{'includeExtensionInIdentifier'} = undef;
	$self->templateContentDirectoryHandler(Plugins::VirtualLibraryCreator::ConfigManager::DirectoryLoader->new(\%directoryHandlerParameters));

	$self->initWebPageMethods();
}

sub initWebPageMethods {
	my $self = shift;

	my %webTemplates = (
		'webList' => 'plugins/VirtualLibraryCreator/list.html',
		'webEditItem' => 'plugins/VirtualLibraryCreator/webpagemethods_edititem.html',
		'webEditCustomizedItem' => 'plugins/VirtualLibraryCreator/webpagemethods_editcustomizeditem.html',
		'webNewItem' => 'plugins/VirtualLibraryCreator/webpagemethods_newitem.html',
		'webNewItemParameters' => 'plugins/VirtualLibraryCreator/webpagemethods_newitemparameters.html',
		'webNewItemTypes' => 'plugins/VirtualLibraryCreator/webpagemethods_newitemtypes.html',
	);

	my @itemDirectories = ();
	my @templateDirectories = ();
	my $dir = $prefs->get("customvirtuallibrariesfolder");
	if (defined $dir && -d $dir) {
		push @itemDirectories, $dir
	}

	my @pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');
	for my $plugindir (@pluginDirs) {
		if (-d catdir($plugindir, "VirtualLibraryCreator", "Templates")) {
			push @templateDirectories, catdir($plugindir, "VirtualLibraryCreator", "Templates");
			main::DEBUGLOG && $log->is_debug && main::DEBUGLOG && $log->is_debug && $log->debug('templateDirectories = '.Data::Dump::dump(\@templateDirectories));
		}
	}
	my %webPageMethodsParameters = (
		'pluginVersion' => $self->pluginVersion,
		'extension' => 'sql',
		'simpleExtension' => 'customvalues.xml',
		'contentPluginHandler' => $self->contentPluginHandler,
		'templatePluginHandler' => $self->templatePluginHandler,
		'contentDirectoryHandler' => $self->contentDirectoryHandler,
		'contentTemplateDirectoryHandler' => $self->templateContentDirectoryHandler,
		'templateDirectoryHandler' => $self->templateDirectoryHandler,
		'templateDataDirectoryHandler' => $self->templateDataDirectoryHandler,
		'parameterHandler' => $self->parameterHandler,
		'contentParser' => $self->contentParser,
		'templateDirectories' => \@templateDirectories,
		'itemDirectories' => \@itemDirectories,
		'customItemDirectory' => $prefs->get("customvirtuallibrariesfolder"),
		'webCallbacks' => $self,
		'webTemplates' => \%webTemplates,
		'browseMenus' => $self->browseMenus,
	);
	$self->webPageMethods(Plugins::VirtualLibraryCreator::ConfigManager::VLWebPageMethods->new(\%webPageMethodsParameters));
}

sub readTemplateConfiguration {
	my ($self, $client) = @_;

	my %templates = ();
	my %globalcontext = ();
	my @pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');
	for my $plugindir (@pluginDirs) {
		main::DEBUGLOG && $log->is_debug && main::DEBUGLOG && $log->is_debug && $log->debug("Checking for dir: ".catdir($plugindir, "VirtualLibraryCreator", "Templates"));
		next unless -d catdir($plugindir, "VirtualLibraryCreator", "Templates");
		$self->templateDirectoryHandler()->readFromDir($client, catdir($plugindir, "VirtualLibraryCreator", "Templates"), \%templates, \%globalcontext);
	}
	return \%templates;
}

sub readItemConfiguration {
	my ($self, $client, $storeInCache) = @_;

	my $dir = $prefs->get("customvirtuallibrariesfolder");
	main::DEBUGLOG && $log->is_debug && main::DEBUGLOG && $log->is_debug && $log->debug("Searching for item configuration in: $dir");

	my %customItems = ();
	my %virtualLibraries = ();
	my %globalcontext = ();
	$self->templates($self->readTemplateConfiguration());

	$globalcontext{'templates'} = $self->templates;

	main::DEBUGLOG && $log->is_debug && main::DEBUGLOG && $log->is_debug && $log->debug("Checking for dir: $dir");
	if (!defined $dir || !-d $dir) {
		main::DEBUGLOG && $log->is_debug && main::DEBUGLOG && $log->is_debug && $log->debug("Skipping custom configuration scan - directory is undefined");
	} else {
		$self->contentDirectoryHandler()->readFromDir($client, $dir, \%customItems, \%globalcontext);
		%virtualLibraries = %customItems;

		$self->templateContentDirectoryHandler()->readFromDir($client, $dir, \%customItems, \%globalcontext);
	}

	my %localItems = ();

	for my $itemId (keys %customItems) {
		my $item = $customItems{$itemId};
		$localItems{$item->{'id'}} = $item;
		$localItems{$item->{'id'}}{'enabled'} = 1 if $virtualLibraries{$item->{'id'}}{'enabled'};
		$localItems{$item->{'id'}}{'hasbrowsemenus'} = 1 if $virtualLibraries{$item->{'id'}}{'hasbrowsemenus'};
		$localItems{$item->{'id'}}{'dailyvlrefresh'} = 1 if $virtualLibraries{$item->{'id'}}{'dailyvlrefresh'};
	}

	for my $key (keys %localItems) {
		postProcessItem($localItems{$key});
	}

	if ($storeInCache) {
		$self->items(\%localItems);
	}
	my %result = (
		'virtuallibraries' => \%virtualLibraries,
		'webvirtuallibraries' => \%localItems,
		'templates' => $self->templates
	);

	return \%result;
}

sub postProcessItem {
	my $item = shift;
	if (defined($item->{'name'})) {
		$item->{'name'} =~ s/\'\'/\'/g;
	}
}

sub webList {
	my ($self, $client, $params) = @_;
	return Plugins::VirtualLibraryCreator::Plugin::handleWebList($client, $params);
}

sub webEditItem {
	my ($self, $client, $params) = @_;

	if (!defined($self->items)) {
		my $itemConfiguration = $self->readItemConfiguration($client);
		$self->items($itemConfiguration->{'webvirtuallibraries'});
	}
	if (!defined($self->templates)) {
		$self->templates($self->readTemplateConfiguration($client));
	}

	return $self->webPageMethods->webEditItem($client, $params, $params->{'item'}, $self->items, $self->templates);
}

sub webEditCustomizedItem {
	my ($self, $client, $params) = @_;

	if (!defined($self->items)) {
		my $itemConfiguration = $self->readItemConfiguration($client);
		$self->items($itemConfiguration->{'virtuallibraries'});
	}

	return $self->webPageMethods->webEditCustomizedItem($client, $params, $params->{'item'}, $self->items);
}

sub webNewItemTypes {
	my ($self, $client, $params) = @_;
	$self->templates($self->readTemplateConfiguration($client));
	return $self->webPageMethods->webNewItemTypes($client, $params, $self->templates);
}

sub webNewItemParameters {
	my ($self, $client, $params) = @_;
	if (!defined($self->templates) || !defined($self->templates->{$params->{'itemtemplate'}})) {
		$self->templates($self->readTemplateConfiguration($client));
	}
	return $self->webPageMethods->webNewItemParameters($client, $params, $params->{'itemtemplate'}, $self->templates);
}

sub webNewItem {
	my ($self, $client, $params) = @_;
	if (!defined($self->templates)) {
		$self->templates($self->readTemplateConfiguration($client));
	}
	return $self->webPageMethods->webNewItem($client, $params, $params->{'itemtemplate'}, $self->templates);
}

sub webSaveNewItem {
	my ($self, $client, $params) = @_;
	if (!defined($self->templates)) {
		$self->templates($self->readTemplateConfiguration($client));
	}
	$params->{'items'} = $self->items;

	return $self->webPageMethods->webSaveNewItem($client, $params, $params->{'itemtemplate'}, $self->templates);
}

sub webSaveItem {
	my ($self, $client, $params) = @_;
	if (!defined($self->templates)) {
		$self->templates($self->readTemplateConfiguration($client));
	}
	$params->{'items'} = $self->items;

	return $self->webPageMethods->webSaveItem($client, $params, $params->{'itemtemplate'}, $self->templates);
}

sub webSaveCustomizedItem {
	my ($self, $client, $params) = @_;
	$params->{'items'} = $self->items;

	return $self->webPageMethods->webSaveCustomizedItem($client, $params);
}

sub webRemoveItem {
	my ($self, $client, $params) = @_;
	if (!defined($self->items)) {
		my $itemConfiguration = $self->readItemConfiguration($client);
		$self->items($itemConfiguration->{'virtuallibraries'});
	}
	return $self->webPageMethods->webDeleteItem($client, $params, $params->{'item'}, $self->items);
}

1;
