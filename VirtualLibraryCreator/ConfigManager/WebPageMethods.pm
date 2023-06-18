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

package Plugins::VirtualLibraryCreator::ConfigManager::WebPageMethods;

use strict;
use warnings;
use utf8;

use base qw(Slim::Utils::Accessor);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use File::Spec::Functions qw(:ALL);
use XML::Simple;
use File::Basename;
use Data::Dumper;
use FindBin qw($Bin);
use HTML::Entities;
use Data::Dumper;

__PACKAGE__->mk_accessor(rw => qw(pluginVersion extension simpleExtension contentPluginHandler templatePluginHandler contentDirectoryHandler contentTemplateDirectoryHandler templateDirectoryHandler templateDataDirectoryHandler parameterHandler contentParser templateDirectories itemDirectories customItemDirectory webCallbacks webTemplates template templateExtension templateDataExtension browseMenus));

my $utf8filenames = 1;
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.virtuallibrarycreator');
my $log = logger('plugin.virtuallibrarycreator');

my %largeFields = map {$_ => 50} qw(virtuallibraryname albumsearchtitle1 albumsearchtitle2 albumsearchtitle3 tracksearchtitle1 tracksearchtitle2 tracksearchtitle3 includepath1 includepath2 includepath3 includepath4 excludepath1 excludepath2 excludepath3 excludepath4);
my %mediumFields = map {$_ => 35} qw(commentssearchstring1 commentssearchstring2 commentssearchstring3);
my %smallFields = map {$_ => 5} qw(nooftracks noofartists noofalbums noofgenres noofyears minlength maxlength minyear maxyear minartisttracks minalbumtracks mingenretracks minplaylisttracks minyeartracks minbitrate maxbitrate minsamplerate maxsamplerate minsamplesize maxsamplesize minbpm maxbpm skipcount maxskipcount browsemenusartistshomemenuweight browsemenusalbumshomemenuweight browsemenusmischomemenuweight libraryinitorder);

sub new {
	my ($class, $parameters) = @_;

	my $self = $class->SUPER::new($parameters);
	$self->pluginVersion($parameters->{'pluginVersion'});
	$self->extension($parameters->{'extension'});
	$self->simpleExtension($parameters->{'simpleExtension'});
	$self->contentPluginHandler($parameters->{'contentPluginHandler'});
	$self->templatePluginHandler($parameters->{'templatePluginHandler'});
	$self->contentDirectoryHandler($parameters->{'contentDirectoryHandler'});
	$self->contentTemplateDirectoryHandler($parameters->{'contentTemplateDirectoryHandler'});
	$self->templateDirectoryHandler($parameters->{'templateDirectoryHandler'});
	$self->templateDataDirectoryHandler($parameters->{'templateDataDirectoryHandler'});
	$self->parameterHandler($parameters->{'parameterHandler'});
	$self->contentParser($parameters->{'contentParser'});
	$self->templateDirectories($parameters->{'templateDirectories'});
	$self->itemDirectories($parameters->{'itemDirectories'});
	$self->customItemDirectory($parameters->{'customItemDirectory'});
	$self->webCallbacks($parameters->{'webCallbacks'});
	$self->webTemplates($parameters->{'webTemplates'});
	$self->browseMenus($parameters->{'browseMenus'});

	if (defined($parameters->{'utf8filenames'})) {
		$utf8filenames = $parameters->{'utf8filenames'};
	}

	$self->templateExtension($parameters->{'templateDirectoryHandler'}->extension);
	$self->templateDataExtension($parameters->{'templateDataDirectoryHandler'}->extension);

	return $self;
}

sub webList {
	my ($self, $client, $params, $items) = @_;
	$params->{'pluginWebPageMethodsItems'} = $items;
	return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webList'}, $params);
}

sub webNewItemTypes {
	my ($self, $client, $params, $templates) = @_;

	my $structuredTemplates = $self->structureItemTypes($templates);
	$log->debug(Dumper($structuredTemplates));

	$params->{'pluginWebPageMethodsTemplates'} = \@{$structuredTemplates};
	$params->{'pluginWebPageMethodsPostUrl'} = $self->webTemplates->{'webNewItemParameters'};

	return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webNewItemTypes'}, $params);
}

sub webEditItem {
	my ($self, $client, $params, $itemId, $itemHash, $templates) = @_;
	$log->debug('Start webEditItem');

	if (defined($itemId) && defined($itemHash->{$itemId})) {
		$params->{'pluginWebPageMethodsEditVLwasEnabledBefore'} = $itemHash->{$itemId}->{'enabled'};

		my $templateData = $self->loadTemplateValues($client, $itemId, $itemHash->{$itemId});
		if (defined($templateData)) {
			my $template = $templates->{lc($templateData->{'id'})};

			if (defined($template)) {
				my %currentParameterValues = ();
				my $templateDataParameters = $templateData->{'parameter'};
				my $vlTemplateVersion = $templateData->{'templateversion'} || 0;
				for my $p (@{$templateDataParameters}) {
					my $values = $p->{'value'};
					if (!defined($values)) {
						my $tmp = $p->{'content'};
						if (defined($tmp)) {
							my @tmpArray = ($tmp);
							$values = \@tmpArray;
						}
					}
					my %valuesHash = ();
					for my $v (@{$values}) {
						if (ref($v) ne 'HASH') {
							$valuesHash{$v} = $v;
						}
					}
					if (!%valuesHash) {
						$valuesHash{''} = '';
					}
					$currentParameterValues{$p->{'id'}} = \%valuesHash;
				}
				if (defined($template->{'parameter'})) {
					my $parameters = $template->{'parameter'};
					if (ref($parameters) ne 'ARRAY') {
						my @parameterArray = ();
						if (defined($parameters)) {
							push @parameterArray, $parameters;
						}
						$parameters = \@parameterArray;
					}
					my @parametersToSelect = ();
					for my $p (@{$parameters}) {
						if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
							if (!defined($currentParameterValues{$p->{'id'}})) {
								my $value = $p->{'value'};
								if (defined($value) || ref($value) ne 'HASH') {
									my %valuesHash = ();
									$valuesHash{$value} = $value;
									$currentParameterValues{$p->{'id'}} = \%valuesHash;
								}
							}

							# add the name of template on which the virtual library is based
							if ($p->{'id'} eq 'virtuallibraryname') {
								$p->{'basetemplate'} = $template->{'name'};
								$p->{'templateversion'} = $template->{'templateversion'};
								$log->debug('new template version: '.Dumper($p->{'templateversion'}));
								$p->{'vltemplateversion'} = $vlTemplateVersion;
								$log->debug('template version of virtual library: '.Dumper($p->{'vltemplateversion'}));
								$p->{'vlid'} = $itemHash->{$itemId}->{'VLID'} if $prefs->get('displayvlids');
							}

							# add size for input element if specified
							if ($p->{'type'} eq 'text' || $p->{'type'} eq 'searchtext') {
								$p->{'elementsize'} = $largeFields{$p->{'id'}} if $largeFields{$p->{'id'}};
								$p->{'elementsize'} = $mediumFields{$p->{'id'}} if $mediumFields{$p->{'id'}};
								$p->{'elementsize'} = $smallFields{$p->{'id'}} if $smallFields{$p->{'id'}};
							}
							if ($p->{'type'} eq 'multivaltext') {
								$p->{'elementsize'} = 50;
							}

							# use params unless required plugin is not enabled
							my $useParameter = 1;
							if (defined($p->{'requireplugins'})) {
								$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
							}
							if ($useParameter) {
								$self->parameterHandler->addValuesToTemplateParameter($p, $currentParameterValues{$p->{'id'}});
								push @parametersToSelect, $p;
							}
						}
					}
					$params->{'pluginWebPageMethodsEditItemParameters'} = \@parametersToSelect;
				}
				$params->{'CTIenabled'} = Slim::Utils::PluginManager->isEnabled('Plugins::CustomTagImporter::Plugin');
				if ($params->{'CTIenabled'}) {
					my $countSql = "select count(distinct attr) from customtagimporter_track_attributes where customtagimporter_track_attributes.type='customtag'";
					$params->{'customtagcount'} = quickSQLcount($countSql);
				}
				$params->{'pluginWebPageMethodsEditItemTemplate'} = lc($templateData->{'id'});
				$params->{'pluginWebPageMethodsEditItemFile'} = $itemId;
				$params->{'pluginWebPageMethodsEditItemFileUnescaped'} = unescape($itemId);
				return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webEditItem'}, $params);
			}
		}
	}
	return $self->webCallbacks->webList($client, $params);
}

sub webEditCustomizedItem {
	my ($self, $client, $params, $itemId, $itemHash) = @_;

	my $browseMenus = $self->browseMenus;
	my $homeMenuDefaultWeight = 110;

	if (defined($itemId) && defined($itemHash->{$itemId}) && defined($itemHash->{$itemId}->{'external'})) {
		$params->{'pluginWebPageMethodsEditItemName'} = $itemHash->{$itemId}->{'name'};
		$params->{'pluginWebPageMethodsEditItemID'} = $itemHash->{$itemId}->{'id'};
		$params->{'pluginWebPageMethodsEditVLID'} = $itemHash->{$itemId}->{'VLID'} if $prefs->get('displayvlids');
		$params->{'enabled'} = $params->{'pluginWebPageMethodsEditVLwasEnabledBefore'} = $itemHash->{$itemId}->{'enabled'} || 0;
		$params->{'dailyrefresh'} = $itemHash->{$itemId}->{'dailyrefresh'} || 0;
		$params->{'libraryinitorder'} = $itemHash->{$itemId}->{'libraryinitorder'} || 50;

		# artistBrowseMenus
		my %webArtistMenus = ('id' => 'browsemenusartists');
		my @artistMenuValues = ();
		my %selectedArtistMenus = ();
		if ($itemHash->{$itemId}->{'artistmenus'}) {
			my @selArtistMenus = split(/,/, $itemHash->{$itemId}->{'artistmenus'});
			%selectedArtistMenus = map {$_ => 1} @selArtistMenus;
			$log->debug('selectedArtistMenus = '.Dumper(\%selectedArtistMenus));
		}
		for my $menu (sort { ($browseMenus->{'artists'}->{$a}->{'sortval'} || 0) <=> ($browseMenus->{'artists'}->{$b}->{'sortval'} || 0)} keys %{$browseMenus->{'artists'}}) {
			my %item = (
				'id' => $menu,
				'name' => $browseMenus->{'artists'}->{$menu}->{'name'},
				'value' => 1,
				'selected' => $selectedArtistMenus{$menu} ? 1 : undef
			);
			push @artistMenuValues, \%item;
		}
		$webArtistMenus{'values'} = \@artistMenuValues;
		$log->debug('webArtistMenus = '.Dumper(\%webArtistMenus));
		$params->{'artistmenus'} = \%webArtistMenus;
		$params->{'browsemenusartistshomemenu'} = $itemHash->{$itemId}->{'artistmenushomemenu'} || 0;
		$params->{'browsemenusartistshomemenuweight'} = $itemHash->{$itemId}->{'artistmenushomemenuweight'} || $homeMenuDefaultWeight;


		# albumBrowseMenus
		my %webAlbumMenus = ('id' => 'browsemenusalbums');
		my @albumMenuValues = ();
		my %selectedAlbumMenus = ();
		if ($itemHash->{$itemId}->{'albummenus'}) {
			my @selAlbumMenus = split(/,/, $itemHash->{$itemId}->{'albummenus'});
			%selectedAlbumMenus = map {$_ => 1} @selAlbumMenus;
			$log->debug('selectedAlbumMenus = '.Dumper(\%selectedAlbumMenus));
		}
		for my $menu (sort { ($browseMenus->{'albums'}->{$a}->{'sortval'} || 0) <=> ($browseMenus->{'albums'}->{$b}->{'sortval'} || 0)} keys %{$browseMenus->{'albums'}}) {
			my %item = (
				'id' => $menu,
				'name' => $browseMenus->{'albums'}->{$menu}->{'name'},
				'value' => 1,
				'selected' => $selectedAlbumMenus{$menu} ? 1 : undef
			);
			push @albumMenuValues, \%item;
		}
		$webAlbumMenus{'values'} = \@albumMenuValues;
		$log->debug('webAlbumMenus = '.Dumper(\%webAlbumMenus));
		$params->{'albummenus'} = \%webAlbumMenus;
		$params->{'browsemenusalbumshomemenu'} = $itemHash->{$itemId}->{'albummenushomemenu'} || 0;
		$params->{'browsemenusalbumshomemenuweight'} = $itemHash->{$itemId}->{'albummenushomemenuweight'} || $homeMenuDefaultWeight + 10;


		# miscBrowseMenus
		my %webMiscMenus = ('id' => 'browsemenusmisc');
		my @miscMenuValues = ();
		my %selectedMiscMenus = ();
		if ($itemHash->{$itemId}->{'miscmenus'}) {
			my @selMiscMenus = split(/,/, $itemHash->{$itemId}->{'miscmenus'});
			%selectedMiscMenus = map {$_ => 1} @selMiscMenus;
			$log->debug('selectedMiscMenus = '.Dumper(\%selectedMiscMenus));
		}
		for my $menu (sort { ($browseMenus->{'misc'}->{$a}->{'sortval'} || 0) <=> ($browseMenus->{'misc'}->{$b}->{'sortval'} || 0)} keys %{$browseMenus->{'misc'}}) {
			my %item = (
				'id' => $menu,
				'name' => $browseMenus->{'misc'}->{$menu}->{'name'},
				'value' => 1,
				'selected' => $selectedMiscMenus{$menu} ? 1 : undef
			);
			push @miscMenuValues, \%item;
		}
		$webMiscMenus{'values'} = \@miscMenuValues;
		$log->debug('webMiscMenus = '.Dumper(\%webMiscMenus));
		$params->{'miscmenus'} = \%webMiscMenus;
		$params->{'browsemenusmischomemenu'} = $itemHash->{$itemId}->{'miscmenushomemenu'} || 0;
		$params->{'browsemenusmischomemenuweight'} = $itemHash->{$itemId}->{'miscmenushomemenuweight'} || $homeMenuDefaultWeight + 20;

		$params->{'includedvlids'} = $itemHash->{$itemId}->{'includedvlids'};
		$params->{'excludedvlids'} = $itemHash->{$itemId}->{'excludedvlids'};

		my $sql = $itemHash->{$itemId}->{'fulltext'};
		if ($sql) {
			$sql = encode_entities($sql, "&<>\'\"");
		}
		$params->{'pluginWebPageMethodsEditItemSql'} = $sql;

		return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webEditCustomizedItem'}, $params);
	}
	return $self->webCallbacks->webList($client, $params);
}

sub webNewItemParameters {
	my ($self, $client, $params, $templateId, $templates) = @_;

	$params->{'pluginWebPageMethodsNewItemTemplate'} = $templateId;
	my $template = $templates->{$templateId};

	if (defined($template->{'parameter'})) {
		my $parameters = $template->{'parameter'};
		if (ref($parameters) ne 'ARRAY') {
			my @parameterArray = ();
			if (defined($parameters)) {
				push @parameterArray, $parameters;
			}
			$parameters = \@parameterArray;
		}
		my @parametersToSelect = ();
		for my $p (@{$parameters}) {
			if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
				# add size for input element if specified
				if ($p->{'type'} eq 'text' || $p->{'type'} eq 'searchtext') {
					$p->{'elementsize'} = $largeFields{$p->{'id'}} if $largeFields{$p->{'id'}};
					$p->{'elementsize'} = $mediumFields{$p->{'id'}} if $mediumFields{$p->{'id'}};
					$p->{'elementsize'} = $smallFields{$p->{'id'}} if $smallFields{$p->{'id'}};
				}
				if ($p->{'type'} eq 'multivaltext') {
					$p->{'elementsize'} = 50;
				}

				# add param unless required plugin is not enabled
				my $useParameter = 1;
				if (defined($p->{'requireplugins'})) {
					$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
				}
				if ($useParameter) {
					$self->parameterHandler->addValuesToTemplateParameter($p);
					push @parametersToSelect, $p;
				}
			}
		}

		$params->{'CTIenabled'} = Slim::Utils::PluginManager->isEnabled('Plugins::CustomTagImporter::Plugin');
		if ($params->{'CTIenabled'}) {
			my $countSql = "select count(distinct attr) from customtagimporter_track_attributes where customtagimporter_track_attributes.type='customtag'";
			$params->{'customtagcount'} = quickSQLcount($countSql);
		}
		$params->{'pluginWebPageMethodsNewItemParameters'} = \@parametersToSelect;
		$params->{'templateName'} = $template->{'name'};
	}
	return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webNewItemParameters'}, $params);
}

sub webNewItem {
	my ($self, $client, $params, $templateId, $templates) = @_;
	$log->debug('Start webNewItem');

	my $templateFile = $templateId;
	my $itemFile = $templateFile;

	my $regex1 = "\\.".$self->templateExtension."\$";
	my $regex2 = ".".$self->templateDataExtension;
	$templateFile =~ s/$regex1/$regex2/;

	$itemFile =~ s/$regex1//;

	my $fileName = lc($params->{'itemparameter_virtuallibraryname'});
	my $templateFileName = basename($itemFile);

	$fileName = lc($templateFileName) if !$fileName;
	$fileName =~ s/[\$#@~!&*()\[\];.,:?^`'"\\\/]+//g;
	$fileName =~ s/^[ \t\s]+|[ \t\s]+$//g;
	$fileName =~ s/[\s]+/_/g;

	my $template = $templates->{$templateId};

	if (-e catfile($self->customItemDirectory, unescape($itemFile).".".$self->extension) || -e catfile($self->customItemDirectory, unescape($itemFile).".".$self->simpleExtension)) {
		my $i = 1;
		while(-e catfile($self->customItemDirectory, unescape($itemFile).$i.".".$self->extension) || -e catfile($self->customItemDirectory, unescape($itemFile).$i.".".$self->simpleExtension)) {
			$i = $i + 1;
		}
		$itemFile .= $i;
	}
	my %templateParameters = ();
	if (defined($template->{'parameter'})) {
		my $parameters = $template->{'parameter'};
		for my $p (@{$parameters}) {
			if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
				my $useParameter = 1;
				if (defined($p->{'requireplugins'})) {
					$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
				}
				if ($useParameter) {
					$self->parameterHandler->addValuesToTemplateParameter($p);
					my $value = $self->parameterHandler->getValueOfTemplateParameter($params, $p);
					$templateParameters{$p->{'id'}} = $value;
				}
			}
		}
	}

	# add the name of template on which the virtual library is based
	$templateParameters{'basetemplate'} = $template->{'name'};

	my $templateFileData = $templateFile;
	my $doParsing = 1;
	my $itemData = undef;

	if ($doParsing) {
		$itemData = $self->fillTemplate($templateFileData, \%templateParameters);
	} else {
		$itemData = $templateFileData;
	}

	$itemData = encode_entities($itemData, "&<>\'\"");
	$params->{'fulltext'} = $itemData;

	$itemFile .= ".".$self->simpleExtension;

	for my $p (keys %{$params}) {
		my $regexp = '^'.$self->parameterHandler->parameterPrefix.'_';
		if ($p =~ /$regexp/) {
			$templateParameters{$p} = $params->{$p};
		}
	}
	$params->{'pluginWebPageMethodsNewItemParameters'} = \%templateParameters;
	$params->{'pluginWebPageMethodsNewItemTemplate'} = $templateId;
	$params->{'pluginWebPageMethodsEditItemFile'} = $itemFile;
	$params->{'pluginWebPageMethodsEditItemFileUnescaped'} = unescape($fileName);
	return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webNewItem'}, $params);
}

sub webDeleteItem {
	my ($self, $client, $params, $itemId, $items) = @_;

	my $dir = $self->customItemDirectory;

	# delete XML file
	my $xmlFile = unescape($itemId).".".$self->simpleExtension;
	my $xmlUrl = catfile($dir, $xmlFile);

	if (defined($dir) && -d $dir && $xmlFile && -e $xmlUrl) {
		unlink($xmlUrl) or do {
			warn "Unable to delete file: ".$xmlUrl.": $!";
		}
	}

	# delete SQLite file
	my $sqlFile = unescape($itemId).".".$self->extension;
	my $sqlFileUrl = catfile($dir, $sqlFile);

	if (defined($dir) && -d $dir && $sqlFile && -e $sqlFileUrl) {
		unlink($sqlFileUrl) or do {
			warn "Unable to delete vlc sql file: ".$sqlFileUrl.": $!";
		}
	}

	$params->{'vlrefresh'} = 4 unless ($prefs->get('vlstempdisabled') || !$items->{$itemId}->{'enabled'}); # don't refresh VLs if globally disabled/paused or deleted VL was disabled
	return $self->webCallbacks->webList($client, $params);
}

sub webSaveItem {
	my ($self, $client, $params, $templateId, $templates) = @_;
	$log->debug('Start webSaveItem (after editing)');

	my $templateFile = $templateId;
	my $regex1 = "\\.".$self->templateExtension."\$";
	my $regex2 = ".".$self->templateDataExtension;
	$templateFile =~ s/$regex1/$regex2/;

	my $regex3 = "\\.".$self->simpleExtension."\$";
	my $itemFile = $params->{'file'};
	$itemFile =~ s/$regex3//;

	my $template = $templates->{$templateId};

	## build sql statement
	my %templateParameters = ();
	if (defined($template->{'parameter'})) {
		my $parameters = $template->{'parameter'};

		if (ref($parameters) ne 'ARRAY') {
			my @parameterArray = ();
			if (defined($parameters)) {
				push @parameterArray, $parameters;
			}
			$parameters = \@parameterArray;
		}
		for my $p (@{$parameters}) {
			if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
				my $useParameter = 1;
				if (defined($p->{'requireplugins'})) {
					$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
				}
				if ($useParameter) {
					if ($self->parameterHandler->parameterIsSpecified($params, $p)) {
						$self->parameterHandler->addValuesToTemplateParameter($p);
					}
					my $value = $self->parameterHandler->getValueOfTemplateParameter($params, $p);
					$templateParameters{$p->{'id'}} = $value;
				}
			}
		}
	}

	$log->debug('templateParameters = '.Dumper(\%templateParameters));

	# add the name of template on which the virtual library is based
	$templateParameters{'basetemplate'} = $template->{'name'};
	$templateParameters{'exacttitlesearch'} = $prefs->get('exacttitlesearch');

	# full file data text
	my $templateFileData = $templateFile;
	my $itemData = $self->fillTemplate($templateFileData, \%templateParameters);
	$params->{'fulltext'} = $itemData;

	$params->{'pluginWebPageMethodsError'} = undef;
	if (!$params->{'itemparameter_virtuallibraryname'}) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_MISSING_VLNAME');
	}

	my $dir = $self->customItemDirectory;
	if (!defined $dir || !-d $dir) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_MISSING_CUSTOMDIR');
	}
	my $file = unescape($params->{'file'});
	my $url = catfile($dir, $file);
	my $customUrl = catfile($dir, $file.".".$self->extension);
	if (!$self->saveSimpleItem($client, $params, $url, $templateId, $templates, $customUrl)) {
		$log->debug('saveSimpleItem FAILED - return to edit mode');
		return Slim::Web::HTTP::filltemplatefile($self->webTemplates->{'webEditItem'}, $params);
	} else {
		$log->debug('saveSimpleItem succeeded');
		$params->{'changedvl'} = $params->{'file'};
		$params->{'vlrefresh'} = 3 unless ((!$templateParameters{'enabled'} && !$params->{'vlwasenabledbefore'}) || $prefs->get('vlstempdisabled')); # don't refresh VLs if still disabled or globally disabled
		return $self->webCallbacks->webList($client, $params);
	}
}

sub webSaveCustomizedItem {
	my ($self, $client, $params) = @_;
	$log->debug('params from save page = '.Dumper($params));

	# gather data from page params
	my %menuOptions = ('browsemenusartists' => 6, 'browsemenusalbums' => 8, 'browsemenusmisc' => 3);
	my (@artistMenus, @albumMenus, @miscMenus) = ();
	foreach my $key (keys %menuOptions) {
		for (1..$menuOptions{$key}) {
			if ($params->{$key.'_'.$_}) {
				push @artistMenus, $_ if $key eq 'browsemenusartists';
				push @albumMenus, $_ if $key eq 'browsemenusalbums';
				push @miscMenus, $_ if $key eq 'browsemenusmisc';
			}
		}
	}
	my $artistMenuString = join (',', @artistMenus);
	my $albumMenuString = join (',', @albumMenus);
	my $miscMenuString = join (',', @miscMenus);

	# create text for sql file
	my $data = "";
	$data .= "-- VirtualLibraryName: ".($params->{'name'} || $params->{'file'})."\n";
	$data .= "-- VirtualLibraryEnabled: yes\n" if $params->{'enabled'};
	$data .= "-- VirtualLibraryDailyRefresh: yes\n" if $params->{'dailyrefresh'};
	$data .= "-- VirtualLibraryInitOrder: ".$params->{'libraryinitorder'}."\n" if $params->{'libraryinitorder'};

	$data .= "-- VirtualLibraryBrowseMenusArtists: ".$artistMenuString."\n" if $artistMenuString;
	$data .= "-- VirtualLibraryBrowseMenusArtistsHomeMenu: yes\n" if $params->{'browsemenusartistshomemenu'};
	$data .= "-- VirtualLibraryBrowseMenusArtistsHomeMenuWeight: ".$params->{'browsemenusartistshomemenuweight'}."\n" if $params->{'browsemenusartistshomemenuweight'};

	$data .= "-- VirtualLibraryBrowseMenusAlbums: ".$albumMenuString."\n" if $albumMenuString;
	$data .= "-- VirtualLibraryBrowseMenusAlbumsHomeMenu: yes\n" if $params->{'browsemenusalbumshomemenu'};
	$data .= "-- VirtualLibraryBrowseMenusAlbumsHomeMenuWeight: ".$params->{'browsemenusalbumshomemenuweight'}."\n" if $params->{'browsemenusalbumshomemenuweight'};

	$data .= "-- VirtualLibraryBrowseMenusMisc: ".$miscMenuString."\n" if $miscMenuString;
	$data .= "-- VirtualLibraryBrowseMenusMiscHomeMenu: yes\n" if $params->{'browsemenusmischomemenu'};
	$data .= "-- VirtualLibraryBrowseMenusMiscHomeMenuWeight: ".$params->{'browsemenusmischomemenuweight'}."\n" if $params->{'browsemenusmischomemenuweight'};

	$data .= "-- VirtualLibraryIncludedVLs: ".$params->{'includedvlids'}."\n" if $params->{'includedvlids'};
	$data .= "-- VirtualLibraryExcludedVLs: ".$params->{'excludedvlids'}."\n" if $params->{'excludedvlids'};

	$data .= $params->{'pluginWebPageMethodsEditItemSql'};

	$log->debug('fulltext file data = '.$data);
	$params->{'fulltext'} = $data;

	my $file = unescape($params->{'pluginWebPageMethodsEditItemID'}).".".$self->extension;
	my $dir = $self->customItemDirectory;
	my $url = catfile($dir, $file);

	if (!$self->saveItem($client, $params, $url)) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_SAVEFAILED');
	} else {
		$params->{'changedvl'} = $params->{'pluginWebPageMethodsEditItemID'};
		$params->{'vlrefresh'} = 3 unless ((!$params->{'enabled'} && !$params->{'vlwasenabledbefore'}) || $prefs->get('vlstempdisabled')); # don't refresh VLs if still disabled or globally disabled
	}
	return $self->webCallbacks->webList($client, $params);
}

sub webSaveNewItem {
	my ($self, $client, $params, $templateId, $templates) = @_;
	$log->debug('Start webSaveNewItem');
	$log->debug('templateId = '.Dumper($templateId));
	$params->{'pluginWebPageMethodsError'} = undef;

	my $templateFile = $templateId;

	my $regex1 = "\\.".$self->templateExtension."\$";
	my $regex2 = ".".$self->templateDataExtension;
	$templateFile =~ s/$regex1/$regex2/;

	my $fallbackFilename = $templateId;
	$fallbackFilename =~ s/$regex1//;

	my $fileName = lc($params->{'itemparameter_virtuallibraryname'}) || lc($fallbackFilename);
	$fileName =~ s/[\$#@~!&*()\[\];.,:?^`'"\\\/]+//g;
	$fileName =~ s/^[ \t\s]+|[ \t\s]+$//g;
	$fileName =~ s/[\s]+/_/g;
	my $dir = $self->customItemDirectory;

	# if file name exists, append number
	if (-e catfile($self->customItemDirectory, unescape($fileName).".".$self->extension) || -e catfile($self->customItemDirectory, unescape($fileName).".".$self->simpleExtension)) {
		my $i = 1;
		while (-e catfile($self->customItemDirectory, unescape($fileName).$i.".".$self->extension) || -e catfile($self->customItemDirectory, unescape($fileName).$i.".".$self->simpleExtension)) {
			$i = $i + 1;
		}
		$fileName .= '_'.$i;
	}
	$params->{'changedvl'} = unescape($fileName);

	my $file = unescape($fileName).".".$self->simpleExtension;
	my $customFile = $file;
	my $regexp1 = ".".$self->simpleExtension."\$";
	$regexp1 =~ s/\./\\./;
	my $regexp2 = ".".$self->extension;
	$customFile =~ s/$regexp1/$regexp2/;
	my $url = catfile($dir, $file);
	my $customUrl = catfile($dir, $customFile);
	$log->debug('file = '.$file);
	$log->debug('customfile = '.$customFile);

	my $template = $templates->{$templateId};

	my %templateParameters = ();
	if (defined($template->{'parameter'})) {
		my $parameters = $template->{'parameter'};
		for my $p (@{$parameters}) {
			if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
				my $useParameter = 1;
				if (defined($p->{'requireplugins'})) {
					$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
				}
				if ($useParameter) {
					$self->parameterHandler->addValuesToTemplateParameter($p);
					my $value = $self->parameterHandler->getValueOfTemplateParameter($params, $p);
					$templateParameters{$p->{'id'}} = $value;
				}
			}
		}
	}

	# add the name of template on which the virtual library is based
	$templateParameters{'basetemplate'} = $template->{'name'};

	my $templateFileData = $templateFile;
	my $itemData = $self->fillTemplate($templateFileData, \%templateParameters);
	$params->{'fulltext'} = $itemData;

	if (!$self->saveSimpleItem($client, $params, $url, $templateId, $templates, $customUrl)) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_SAVEFAILED');
	} else {
		$params->{'vlrefresh'} = 2 if $templateParameters{'enabled'} && !$prefs->get('vlstempdisabled'); # don't refresh VLs if (globally) disabled;
	}
	return $self->webCallbacks->webList($client, $params);
}

sub saveSimpleItem {
	my ($self, $client, $params, $url, $templateId, $templates, $customUrl) = @_;
	my $fh;
	$log->debug('Start saveSimpleItem');
	my $regexp = $self->simpleExtension;
	$regexp =~ s/\./\\./;
	$regexp = ".*".$regexp."\$";
	if (!($url =~ /$regexp/)) {
		$url .= ".".$self->simpleExtension;
	}

	if (!($params->{'pluginWebPageMethodsError'})) {
		$log->debug("Opening configuration file: $url");
		open($fh, ">:encoding(UTF-8)", $url) or do {
			$params->{'pluginWebPageMethodsError'} = "Error saving $url:".$!;
			$log->error("Error saving $url:".$!);
		};
	}

	# write simple file
	if (!($params->{'pluginWebPageMethodsError'})) {
		my $template = $templates->{$templateId};
		my %templateParameters = ();
		my $data = "";
		$data .= "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<virtuallibrarycreator>\n\t<template>\n\t\t<id>".$templateId."</id>";
		# include template version
		$data .= "\n\t\t<templateversion>".$template->{'templateversion'}."</templateversion>" if $template->{'templateversion'};

		if (defined($template->{'parameter'})) {
			my $parameters = $template->{'parameter'};
			if (ref($parameters) ne 'ARRAY') {
				my @parameterArray = ();
				if (defined($parameters)) {
					push @parameterArray, $parameters;
				}
				$parameters = \@parameterArray;
			}
			for my $p (@{$parameters}) {
				if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
					my $useParameter = 1;
					if (defined($p->{'requireplugins'})) {
						$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
					}
					if ($useParameter) {
						if ($self->parameterHandler->parameterIsSpecified($params, $p)) {
							$self->parameterHandler->addValuesToTemplateParameter($p);
						}
						my $value = $self->parameterHandler->getXMLValueOfTemplateParameter($params, $p);
						my $rawValue = '';
						if (defined($p->{'rawvalue'}) && $p->{'rawvalue'}) {
							$rawValue = " rawvalue=\"1\"";
						}
						if ($p->{'quotevalue'}) {
							$data .= "\n\t\t<parameter type=\"text\" id=\"".$p->{'id'}."\" quotevalue=\"1\"$rawValue>";
						} else {
							$data .= "\n\t\t<parameter type=\"text\" id=\"".$p->{'id'}."\"$rawValue>";
						}
						$data .= $value.'</parameter>';
					}
				}
			}
		}
		$data .= "\n\t</template>\n</virtuallibrarycreator>\n";
		my $encoding = Slim::Utils::Unicode::encodingFromString($data);
		if ($encoding eq 'utf8') {
			$data = Slim::Utils::Unicode::utf8toLatin1($data);
		}

		$log->debug("Writing to file: $url");
		print $fh $data;
		$log->debug('Writing to file succeeded');
		close $fh;
	}

	# write adv file
	if (!($params->{'pluginWebPageMethodsError'})) {
		$self->saveItem($client, $params, $customUrl);
	}

	if ($params->{'pluginWebPageMethodsError'}) {
		my $template = $templates->{$templateId};
		if (defined($template->{'parameter'})) {
			my @templateDataParameters = ();
			my $parameters = $template->{'parameter'};
			if (ref($parameters) ne 'ARRAY') {
				my @parameterArray = ();
				if (defined($parameters)) {
					push @parameterArray, $parameters;
				}
				$parameters = \@parameterArray;
			}
			for my $p (@{$parameters}) {
				my $useParameter = 1;
				if (defined($p->{'requireplugins'})) {
					$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
				}
				if ($useParameter) {
					$self->parameterHandler->addValuesToTemplateParameter($p);
					my $value = $self->parameterHandler->getXMLValueOfTemplateParameter($params, $p);
					if (defined($value) && $value ne '') {
						my $valueData = '<data>'.$value.'</data>';
						my $xmlValue = eval { XMLin($valueData, forcearray => ['value'], keyattr => []) };
						if (defined($xmlValue)) {
							$xmlValue->{'id'} = $p->{'id'};
							push @templateDataParameters, $xmlValue;
						}
					}
				}
			}
			my %currentParameterValues = ();
			for my $p (@templateDataParameters) {
				my $values = $p->{'value'};
				my %valuesHash = ();
				for my $v (@{$values}) {
					if (ref($v) ne 'HASH') {
						$valuesHash{$v} = $v;
					}
				}
				if (!%valuesHash) {
					$valuesHash{''} = '';
				}
				$currentParameterValues{$p->{'id'}} = \%valuesHash;
			}

			my @parametersToSelect = ();
			for my $p (@{$parameters}) {
				if (defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'})) {
					my $useParameter = 1;
					if (defined($p->{'requireplugins'})) {
						$useParameter = Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
					}
					if ($useParameter) {
						$self->parameterHandler->setValueOfTemplateParameter($p, $currentParameterValues{$p->{'id'}});
						push @parametersToSelect, $p;
					}
				}
			}
			my %templateParameters = ();
			for my $p (keys %{$params}) {
				my $regexp = '^'.$self->parameterHandler->parameterPrefix.'_';
				if ($p =~ /$regexp/) {
					$templateParameters{$p} = $params->{$p};
				}
			}

			$params->{'pluginWebPageMethodsEditItemParameters'} = \@parametersToSelect;
			$params->{'pluginWebPageMethodsNewItemParameters'} =\%templateParameters;
		}
		$params->{'pluginWebPageMethodsNewItemTemplate'} = $templateId;
		$params->{'pluginWebPageMethodsEditItemTemplate'} = $templateId;
		$params->{'pluginWebPageMethodsEditItemFile'} = $params->{'file'};
		$params->{'pluginWebPageMethodsEditItemFileUnescaped'} = unescape($params->{'pluginWebPageMethodsEditItemFile'});
		return undef;
	} else {
		return 1;
	}
}

sub saveItem {
	my ($self, $client, $params, $url) = @_;
	my $fh;
	$log->debug('Start saveItem');

	my $regexp = ".".$self->extension."\$";
	$regexp =~ s/\./\\./;
	if (!($url =~ /$regexp/)) {
		$url .= ".".$self->extension;
	}
	my $data = Slim::Utils::Unicode::utf8decode_locale($params->{'fulltext'});
	$data =~ s/\r+\n/\n/g; # Remove any extra \r character, will create duplicate linefeeds on Windows if not removed

	if (!($params->{'pluginWebPageMethodsError'})) {
		$log->debug("Opening configuration file: $url");
		open($fh, ">:encoding(UTF-8)", $url) or do {
			$params->{'pluginWebPageMethodsError'} = "Error saving $url: ".$!;
			$log->error("Error saving $url:".$!);
		};
	}
	if (!($params->{'pluginWebPageMethodsError'})) {

		$log->debug("Writing to file: $url");
		my $encoding = Slim::Utils::Unicode::encodingFromString($data);
		if ($encoding eq 'utf8') {
			$data = Slim::Utils::Unicode::utf8toLatin1($data);
		}
		print $fh $data;
		$log->debug('Writing to file succeeded');
		close $fh;
	}

	if ($params->{'pluginWebPageMethodsError'}) {
		$params->{'pluginWebPageMethodsEditItemFile'} = $params->{'file'};
		$params->{'pluginWebPageMethodsEditItemData'} = encode_entities($params->{'text'});
		$params->{'pluginWebPageMethodsEditItemFileUnescaped'} = unescape($params->{'pluginWebPageMethodsEditItemFile'});
		return undef;
	} else {
		return 1;
	}
}

sub structureItemTypes {
	my ($self, $templates) = @_;
	my @templatesArray = ();

	for my $key (keys %{$templates}) {
		push @templatesArray, $templates->{$key};
	}
	return \@templatesArray;
}

sub loadItemDataFromAnyDir {
	my ($self, $itemId) = @_;
	my $data = undef;

	my $directories = $self->itemDirectories;
	for my $dir (@{$directories}) {
		$data = $self->contentDirectoryHandler->readDataFromDir($dir, $itemId);
		if (defined($data)) {
			last;
		}
	}
	return $data;
}

sub loadTemplateFromAnyDir {
	my ($self, $templateId) = @_;
	my $data = undef;

	my $directories = $self->templateDirectories;
	for my $dir (@{$directories}) {
		$data = $self->templateDirectoryHandler->readDataFromDir($dir, $templateId);
		if (defined($data)) {
			last;
		}
	}
	return $data;
}

sub loadTemplateDataFromAnyDir {
	my ($self, $templateId) = @_;
	my $data = undef;

	my $directories = $self->templateDirectories;
	for my $dir (@{$directories}) {
		$data = $self->templateDataDirectoryHandler->readDataFromDir($dir, $templateId);
		if (defined($data)) {
			last;
		}
	}
	return $data;
}

sub loadTemplateValues {
	my ($self, $client, $itemId, $item) = @_;
	my $templateData = undef;

	my $itemDirectories = $self->itemDirectories;
	for my $dir (@{$itemDirectories}) {
		my $content = $self->contentTemplateDirectoryHandler->readDataFromDir($dir, $itemId);
		if (defined($content)) {
			my $xml = eval { XMLin($content, forcearray => ["parameter", "value"], keyattr => []) };
			if ($@) {
				$log->error("Failed to parse configuration because: $@");
			} else {
				$templateData = $xml->{'template'};
			}
		}
		if (defined($templateData)) {
			last;
		}
	}
	return $templateData;
}

sub getTemplate {
	my $self = shift;
	if (!defined($self->template)) {
		$self->template(Template->new({
			INCLUDE_PATH => $self->templateDirectories,
			COMPILE_DIR => catdir($serverPrefs->get('cachedir'), 'templates'),
			FILTERS => {
				'string' => \&Slim::Utils::Strings::string,
				'getstring' => \&Slim::Utils::Strings::getString,
				'resolvestring' => \&Slim::Utils::Strings::resolveString,
				'nbsp' => \&nonBreaking,
				'uri' => \&URI::Escape::uri_escape_utf8,
				'unuri' => \&URI::Escape::uri_unescape,
				'utf8decode' => \&Slim::Utils::Unicode::utf8decode,
				'utf8encode' => \&Slim::Utils::Unicode::utf8encode,
				'utf8on' => \&Slim::Utils::Unicode::utf8on,
				'utf8off' => \&Slim::Utils::Unicode::utf8off,
				'fileurl' => \&fileURLFromPath,
			},
			EVAL_PERL => 1,
		}));
	}
	return $self->template;
}

sub fileURLFromPath {
	my $path = shift;
	if ($utf8filenames) {
		$path = Slim::Utils::Unicode::utf8off($path);
	} else {
		$path = Slim::Utils::Unicode::utf8on($path);
	}
	$path = decode_entities($path);
	$path =~ s/\'\'/\'/g;
	$path = Slim::Utils::Misc::fileURLFromPath($path);
	$path = Slim::Utils::Unicode::utf8on($path);
	$path =~ s/%/\\%/g;
	$path =~ s/\'/\'\'/g;
	$path = encode_entities($path, "&<>\'\"");
	return $path;
}

sub fillTemplate {
	my ($self, $filename, $params) = @_;

	my $output = '';
	$params->{'LOCALE'} = 'utf-8';
	my $template = $self->getTemplate();
	if (!$template->process($filename, $params, \$output)) {
		$log->error("ERROR parsing template: ".$template->error());
	}
	return $output;
}

sub quickSQLcount {
	my $dbh = Slim::Schema->storage->dbh();
	my $sqlstatement = shift;
	my $thisCount;
	my $sth = $dbh->prepare($sqlstatement);
	$sth->execute();
	$sth->bind_columns(undef, \$thisCount);
	$sth->fetch();
	$sth->finish;
	return $thisCount;
}

*escape = \&URI::Escape::uri_escape_utf8;

sub unescape {
	my ($in, $isParam) = @_;
	return if !$in;
	$in =~ s/\+/ /g if $isParam;
	$in =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
	return $in;
}

1;
