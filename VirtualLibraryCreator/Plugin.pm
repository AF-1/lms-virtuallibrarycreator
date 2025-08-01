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

package Plugins::VirtualLibraryCreator::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);
use Slim::Schema;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use File::Spec::Functions qw(:ALL);
use FindBin qw($Bin);
use Time::HiRes qw(time);

use Plugins::VirtualLibraryCreator::ConfigManager::Main;
use Plugins::VirtualLibraryCreator::Common ':all';
use Plugins::VirtualLibraryCreator::Importer;

my $virtualLibraries = undef;
my $webVirtualLibraries = undef;
my $sqlerrors = '';
my $configManager = undef;
my $pluginVersion = undef;
my $isPostScanCall = 0;
my %browseMenus = ();

my $prefs = preferences('plugin.virtuallibrarycreator');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.virtuallibrarycreator',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_VIRTUALLIBRARYCREATOR',
});
my $cache = Slim::Utils::Cache->new();

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	$pluginVersion = Slim::Utils::PluginManager->dataForPlugin($class)->{'version'};

	initPrefs();

	if (main::WEBUI) {
		require Plugins::VirtualLibraryCreator::Settings;
		Plugins::VirtualLibraryCreator::Settings->new($class);
	}

	Slim::Control::Request::subscribe(sub{
		$isPostScanCall = 1;
		setRefreshCBTimer();
	},[['rescan'],['done']]);
}

sub initPrefs {
	$prefs->init({
		customdirparentfolderpath => Slim::Utils::OSDetect::dirsFor('prefs'),
		browsemenus_parentfoldername => 'My VLC Menus',
		browsemenus_parentfoldericon => 1,
		dailyvlrefreshtime => '02:30',
		displayhasbrowsemenus => 1,
		displayisdailyrefreshed => 1,
		scheduledinitdelay => 3
	});

	createVirtualLibrariesFolder();
	$prefs->set('manualrefresh', 0);

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $virtualLibrariesFolder = catdir($_[1], 'VirtualLibraryCreator');
		eval {
			mkdir($virtualLibrariesFolder, 0755) unless (-d $virtualLibrariesFolder);
		} or do {
			$log->error("Could not create VLC folder in parent folder '$_[1]'!");
			return;
		};
		$prefs->set('customvirtuallibrariesfolder', $virtualLibrariesFolder);
		return 1;
	}, 'customdirparentfolderpath');

	$prefs->setValidate({
		validator => sub {
			if (defined $_[1]) {
				return if $_[1] eq '';
				return if $_[1] =~ m|[\^{}$@<>"#%?*:/\|\\]|;
				return if $_[1] =~ m|.{61,}|;
			}
			return 1;
		}
	}, 'browsemenus_parentfoldername');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'dailyvlrefreshtime');

	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('VLC parent folder name for browse menus or its icon changed. Reinitializing collected VL menus.');
			initCollectedVLMenus();
		}, 'browsemenus_parentfoldername', 'browsemenus_parentfoldericon');
	$prefs->setChange(\&dailyVLrefreshScheduler, 'dailyvlrefreshtime');

	%browseMenus = ('artists' => {1 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS'), 'sortval' => 1},
									5 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS'), 'sortval' => 2},
									2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS'), 'sortval' => 3},
									3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS'), 'sortval' => 4},
									6 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS'), 'sortval' => 5},
									4 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS'), 'sortval' => 6}
								},
						'albums' => {1 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS'), 'sortval' => 1},
									3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM'), 'sortval' => 7},
									4 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS'), 'sortval' => 8},
									5 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY'), 'sortval' => 9},
									6 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS'), 'sortval' => 10},
									7 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE'), 'sortval' => 11},
									8 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR'), 'sortval' => 12},
									2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM'), 'sortval' => 2},
									9 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ALBUM'), 'sortval' => 3},
									10 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM'), 'sortval' => 4},
									11 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_ALBUM'), 'sortval' => 5},
								},
						'misc' => {1 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES'), 'sortval' => 1},
									2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS'), 'sortval' => 2},
									3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS'), 'sortval' => 3}}
								);
}

sub postinitPlugin {
	my $class = shift;
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		# plugin cache
		my $cachePluginVersion = $cache->get('vlc_pluginversion');
		main::DEBUGLOG && $log->is_debug && $log->debug('current plugin version = '.$pluginVersion.' -- cached plugin version = '.Data::Dump::dump($cachePluginVersion));

		refreshSQLCache() if (!$cachePluginVersion || $cachePluginVersion ne $pluginVersion || !$cache->get('vlc_contributorlist_all') || !$cache->get('vlc_contributorlist_albumartists') || !$cache->get('vlc_contributorlist_composers') || !$cache->get('vlc_genrelist') || !$cache->get('vlc_contenttypes') || !$cache->get('vlc_releasetypes'));

		getConfigManager();
		initVirtualLibrariesDelayed();
	}
}

sub initHomeVLMenus {
	main::DEBUGLOG && $log->is_debug && $log->debug('Started initializing HOME VL menus.');
	my $started = time();

	# deregister all VLC menus
	main::DEBUGLOG && $log->is_debug && $log->debug('Deregistering VLC menus.');
	deregAllMenus();

	## update list of available virtual library VLC definitions
	getVLCvirtualLibraryList();

	if (keys %{$virtualLibraries} > 0) {
		### get enabled browse menus for home menu
		my @enabledHomeBrowseMenus = ();
		foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
			next if !$virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
			my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
			my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($VLCitemID)) if defined $VLCitemID && $VLCitemID ne '';
			main::DEBUGLOG && $log->is_debug && $log->debug('VLID = '.Data::Dump::dump($VLID));
			my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
			next if !$library_id;

			if (($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'})) {
					push @enabledHomeBrowseMenus, $thisVLCvirtualLibrary;
			}
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('enabled home menu browse menus = '.scalar(@enabledHomeBrowseMenus)."\n".Data::Dump::dump(\@enabledHomeBrowseMenus));

		### create browse menus for home folder
		if (scalar @enabledHomeBrowseMenus > 0) {
			my @homeBrowseMenus = ();

			foreach my $thisVLCvirtualLibrary (sort @enabledHomeBrowseMenus) {
				my $enabled = $virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
				next if !$enabled;
				my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
				my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($VLCitemID)) if defined $VLCitemID && $VLCitemID ne '';
				main::DEBUGLOG && $log->is_debug && $log->debug('VLID = '.Data::Dump::dump($VLID));

				my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
				next if !$library_id;

				if (defined $enabled && defined $library_id) {
					my $browsemenu_name = $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'};
					main::DEBUGLOG && $log->is_debug && $log->debug('browsemenu_name = '.$browsemenu_name);

					# get menus from browse menu strings
					my %artistMenus = ();
					if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) {
						my @selArtistMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'});
						%artistMenus = map {$_ => 1} @selArtistMenus;
						main::DEBUGLOG && $log->is_debug && $log->debug('selectedArtistMenus = '.Data::Dump::dump(\%artistMenus));
					}
					my $artistHomeMenusWeight = $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenuweight'};

					my %albumMenus = ();
					if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) {
						my @selAlbumMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'});
						%albumMenus = map {$_ => 1} @selAlbumMenus;
						main::DEBUGLOG && $log->is_debug && $log->debug('selectedAlbumMenus = '.Data::Dump::dump(\%albumMenus));
					}
					my $albumHomeMenusWeight = $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenuweight'};

					my %miscMenus = ();
					if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'}) {
						my @selMiscMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'});
						%miscMenus = map {$_ => 1} @selMiscMenus;
						main::DEBUGLOG && $log->is_debug && $log->debug('selectedMiscMenus = '.Data::Dump::dump(\%miscMenus));
					}
					my $miscHomeMenusWeight = $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenuweight'};

					## menu generator ##
					my $menuGenerator = sub {
						my ($menuStringToken, $id, $feed, $icon, $offset, $params, $isRandom) = @_;

						my $menuString = registerCustomString("$browsemenu_name - " . string($menuStringToken));
						my $useCache = $isRandom ? 0 : 1;
						my $homeMenusWeight = 209 + $offset;

						if ($feed eq 'artists') {
							$feed = \&Slim::Menu::BrowseLibrary::_artists;
							$homeMenusWeight = $artistHomeMenusWeight + $offset if $artistHomeMenusWeight;
							if ($menuStringToken eq 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS_HOMEDISPLAYED') {
								$menuString = registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS_HOMEDISPLAYED'));
								$homeMenusWeight = 12;
							}
						} elsif ($feed eq 'genres') {
							$feed = \&Slim::Menu::BrowseLibrary::_genres;
							$homeMenusWeight = $miscHomeMenusWeight + $offset if $miscHomeMenusWeight;
							if ($menuStringToken eq 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED') {
								$menuString = registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED'));
								$homeMenusWeight = 24;
							}
						} elsif ($feed eq 'years') {
							$feed = \&Slim::Menu::BrowseLibrary::_years;
							$homeMenusWeight = $miscHomeMenusWeight + $offset if $miscHomeMenusWeight;
						} elsif ($feed eq 'tracks') {
							$feed = \&Slim::Menu::BrowseLibrary::_tracks;
							$homeMenusWeight = $miscHomeMenusWeight + $offset if $miscHomeMenusWeight;
						} else {
							$feed = \&Slim::Menu::BrowseLibrary::_albums;
							$homeMenusWeight = $albumHomeMenusWeight + $offset if $albumHomeMenusWeight;
							if ($menuStringToken eq 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS_HOMEDISPLAYED') {
								$menuString = registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS_HOMEDISPLAYED'));
								$homeMenusWeight = 23;
							}
						}

						return {
								type => 'link',
								name => $menuString,
								homeMenuText => $menuString,
								icon => $icon,
								jiveIcon => $icon,
								id => $VLID . $id,
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => $homeMenusWeight,
								cache => $useCache,
								feed => $feed,
								params => $params,
						};
					};

					### ARTIST MENUS ###

					# user configurable list of artists
					if ($artistMenus{1}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS',
							'_BROWSEMENU_ALLARTISTS',
							'artists',
							'html/images/artists.png',
							0,
							{ library_id => $library_id }
						);
					}

					# Album artists
					if ($artistMenus{5}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS',
							'_BROWSEMENU_ALBUMARTISTS',
							'artists',
							'html/images/artists.png',
							1,
							{
								library_id => $library_id,
								role_id => 'ALBUMARTIST'
							}
						);
					}

					# Composers
					my $menuStringToken = lc($browsemenu_name) eq 'composers' ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS_HOMEDISPLAYED' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS';
					if ($artistMenus{2}) {
						push @homeBrowseMenus, $menuGenerator->(
							$menuStringToken,
							'_BROWSEMENU_COMPOSERS',
							'artists',
							'html/images/artists.png',
							2,
							{
								library_id => $library_id,
								role_id => 'COMPOSER'
							}
						);
					}

					# Conductors
					if ($artistMenus{3}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS',
							'_BROWSEMENU_CONDUCTORS',
							'artists',
							'html/images/artists.png',
							3,
							{
								library_id => $library_id,
								role_id => 'CONDUCTOR'
							}
						);
					}

					# Track Artists
					if ($artistMenus{6}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS',
							'_BROWSEMENU_TRACKARTISTS',
							'artists',
							'html/images/artists.png',
							4,
							{
								library_id => $library_id,
								role_id => 'TRACKARTIST'
							}
						);
					}

					# Bands
					if ($artistMenus{4}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS',
							'_BROWSEMENU_BANDS',
							'artists',
							'html/images/artists.png',
							5,
							{
								library_id => $library_id,
								role_id => 'BAND'
							}
						);
					}

					### ALBUM MENUS ###

					# All albums
					if ($albumMenus{1}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS',
							'_BROWSEMENU_HOME_ALLALBUMS',
							'albums',
							'html/images/albums.png',
							6,
							{ library_id => $library_id }
						);
					}

					# All albums sorted by artist, year, album title
					if ($albumMenus{2}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM',
							'_BROWSEMENU_HOME_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM',
							'albums',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
							7,
							{
								library_id => $library_id,
								'orderBy' => 'artflow',
							}
						);
					}

					# All albums sorted by year, album title
					if ($albumMenus{9}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ALBUM',
							'_BROWSEMENU_HOME_ALLALBUMS_SORTED_YEAR_ALBUM',
							'albums',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
							8,
							{
								library_id => $library_id,
								'orderBy' => 'yearalbum',
							}
						);
					}

					# All albums sorted by year, artist, album title
					if ($albumMenus{10}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM',
							'_BROWSEMENU_HOME_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM',
							'albums',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
							9,
							{
								library_id => $library_id,
								'orderBy' => 'yearartistalbum',
							}
						);
					}

					# All albums sorted by artist, album title
					if ($albumMenus{11}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_ALBUM',
							'_BROWSEMENU_HOME_ALLALBUMS_SORTED_ARTIST_ALBUM',
							'albums',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
							10,
							{
								library_id => $library_id,
								'orderBy' => 'artistalbum',
							}
						);
					}

					# Random Albums
					if ($albumMenus{3}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM',
							'_BROWSEMENU_HOME_RANDOMALBUMS',
							'albums',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
							12,
							{
								library_id => $library_id,
								mode => 'randomalbums',
								sort => 'random',
							},
							1
						);
					}

					# Compilations only
					if ($albumMenus{5}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY',
							'_BROWSEMENU_HOME_COMPISONLY',
							'albums',
							'html/images/albums.png',
							14,
							{
								library_id => $library_id,
								artist_id => Slim::Schema->variousArtistsObject->id,
								mode => 'vaalbums',
								compilation => 1,
							}
						);
					}

					# Random compilations
					if ($albumMenus{6}) {
						my $menuStringToken = lc($browsemenu_name) eq 'compilations random' ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS_HOMEDISPLAYED' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS';

						push @homeBrowseMenus, $menuGenerator->(
							$menuStringToken,
							'_BROWSEMENU_HOME_RANDOMCOMPIS',
							'albums',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
							15,
							{
								library_id => $library_id,
								artist_id => Slim::Schema->variousArtistsObject->id,
								mode => 'randomalbums',
								sort => 'random',
								compilation => 1,
							},
							1
						);
					}

					# Compilations by genre
					if ($albumMenus{7}) {
						my $menuStringToken = lc($browsemenu_name) eq 'compilations by genre' ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE';
						push @homeBrowseMenus, $menuGenerator->(
							$menuStringToken,
							'_BROWSEMENU_HOME_COMPISBYGENRE',
							'genres',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
							16,
							{
								library_id => $library_id,
								artist_id => Slim::Schema->variousArtistsObject->id,
								mode => 'genres',
								sort => 'title',
								compilation => 1,
							}
						);
					}

					# Compilations by year
					if ($albumMenus{8}) {
						my $menuStringToken = lc($browsemenu_name) eq lc('Compilations by year') ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR';
						push @homeBrowseMenus, $menuGenerator->(
							$menuStringToken,
							'_BROWSEMENU_HOME_COMPISBYYEAR',
							'years',
							'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png',
							17,
							{
								library_id => $library_id,
								artist_id => Slim::Schema->variousArtistsObject->id,
								mode => 'years',
								sort => 'title',
								compilation => 1,
							}
						);
					}

					### OTHER MENUS ###

					# Genres menu
					if ($miscMenus{1}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES',
							'_BROWSEMENU_GENRE_ALL',
							'genres',
							'html/images/genres.png',
							18,
							{ library_id => $library_id }
						);
					}

					# Years menu
					if ($miscMenus{2}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS',
							'_BROWSEMENU_YEARS',
							'years',
							'html/images/years.png',
							19,
							{ library_id => $library_id }
						);
					}

					# Tracks menu
					if ($miscMenus{3}) {
						push @homeBrowseMenus, $menuGenerator->(
							'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS',
							'_BROWSEMENU_TRACKS',
							'tracks',
							'html/images/playlists.png',
							20,
							{
								library_id => $library_id,
								sort => 'title',
							}
						);
					}
				}
			}
			if (scalar(@homeBrowseMenus) > 0) {
				foreach (@homeBrowseMenus) {
					Slim::Menu::BrowseLibrary->deregisterNode($_);
					Slim::Menu::BrowseLibrary->registerNode($_);
				}
			}
		}

	main::INFOLOG && $log->is_info && $log->info('Finished initializing home VL browse menus after '.(time() - $started).' secs.');
	initCollectedVLMenus();
	}
}

sub initCollectedVLMenus {
	main::DEBUGLOG && $log->is_debug && $log->debug('Started initializing collected VL menus.');
	my $started = time();

	my $browsemenus_parentfolderID = 'PLUGIN_VLC_VLCPARENTFOLDER';
	my $browsemenus_parentfoldername = $prefs->get('browsemenus_parentfoldername') || 'My VLC Menus';

	# deregister parent folder menu
	Slim::Menu::BrowseLibrary->deregisterNode($browsemenus_parentfolderID);
	my $nameToken = registerCustomString($browsemenus_parentfoldername);

	### get enabled browse menus for VLC parent folder
	if (keys %{$virtualLibraries} > 0) {
		my @enabledCollectedBrowseMenus = ();
		foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
			next if !$virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
			my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
			my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($VLCitemID)) if defined $VLCitemID && $VLCitemID ne '';
			main::DEBUGLOG && $log->is_debug && $log->debug('VLID = '.Data::Dump::dump($VLID));
			my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
			next if !$library_id;

			if (($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'})) {
					push @enabledCollectedBrowseMenus, $thisVLCvirtualLibrary;
			}
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('enabled browse menus collected in VLC parent folder = '.scalar(@enabledCollectedBrowseMenus)."\n".Data::Dump::dump(\@enabledCollectedBrowseMenus));

		### create browse menus collected in VLC parent folder
		if (scalar @enabledCollectedBrowseMenus > 0) {
			my $browsemenus_parentfoldericon = $prefs->get('browsemenus_parentfoldericon');
			my $iconPath;
			if ($browsemenus_parentfoldericon == 1) {
				$iconPath = 'plugins/VirtualLibraryCreator/html/images/parentfolder-browsemenuicon.png';
			} elsif ($browsemenus_parentfoldericon == 2) {
				$iconPath = 'plugins/VirtualLibraryCreator/html/images/parentfolder-folder_svg.png';
			} else {
				$iconPath = 'plugins/VirtualLibraryCreator/html/images/parentfolder-music_svg.png';
			}
			main::DEBUGLOG && $log->is_debug && $log->debug('browsemenus_parentfoldericon = '.$browsemenus_parentfoldericon);
			main::DEBUGLOG && $log->is_debug && $log->debug('iconPath = '.$iconPath);

			Slim::Menu::BrowseLibrary->registerNode({
				type => 'link',
				name => $nameToken,
				id => $browsemenus_parentfolderID,
				feed => sub {
					my ($client, $cb, $args, $pt) = @_;
					my @collectedBrowseMenus = ();
					foreach my $thisVLCvirtualLibrary (sort @enabledCollectedBrowseMenus) {
						my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($virtualLibraries->{$thisVLCvirtualLibrary}->{'id'}));
						main::DEBUGLOG && $log->is_debug && $log->debug('VLID = '.Data::Dump::dump($VLID));
						my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
						my $pt = {library_id => $library_id, 'variousartistsid' => Slim::Schema->variousArtistsObject->id};
						my $browsemenu_name = $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'};
						main::DEBUGLOG && $log->is_debug && $log->debug('browsemenu_name = '.$browsemenu_name);

						# get menus from browse menu strings
						my %artistMenus = ();
						if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) {
							my @selArtistMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'});
							%artistMenus = map {$_ => 1} @selArtistMenus;
							main::DEBUGLOG && $log->is_debug && $log->debug('selectedArtistMenus = '.Data::Dump::dump(\%artistMenus));
						}

						my %albumMenus = ();
						if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) {
							my @selAlbumMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'});
							%albumMenus = map {$_ => 1} @selAlbumMenus;
							main::DEBUGLOG && $log->is_debug && $log->debug('selectedAlbumMenus = '.Data::Dump::dump(\%albumMenus));
						}

						my %miscMenus = ();
						if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'}) {
							my @selMiscMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'});
							%miscMenus = map {$_ => 1} @selMiscMenus;
							main::DEBUGLOG && $log->is_debug && $log->debug('selectedMiscMenus = '.Data::Dump::dump(\%miscMenus));
						}

						## menu generator ##
						my $menuGenerator = sub {
							my ($menuStringToken, $id, $feed, $icon, $offset, $params, $isRandom) = @_;

							my $useCache = $isRandom ? 0 : 1;
							if ($feed eq 'artists') {
								$feed = \&Slim::Menu::BrowseLibrary::_artists;
							} elsif ($feed eq 'genres') {
								$feed = \&Slim::Menu::BrowseLibrary::_genres;
							} elsif ($feed eq 'years') {
								$feed = \&Slim::Menu::BrowseLibrary::_years;
							} elsif ($feed eq 'tracks') {
								$feed = \&Slim::Menu::BrowseLibrary::_tracks;
							} else {
								$feed = \&Slim::Menu::BrowseLibrary::_albums;
							}

							return {
									type => 'link',
									name => $browsemenu_name.' - '.string($menuStringToken),
									icon => $icon,
									jiveIcon => $icon,
									id => $VLID . $id,
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 209 + $offset,
									cache => $useCache,
									url => $feed,
									passthrough => [ $params ],
							};
						};

						### ARTISTS MENUS ###

						# user configurable list of artists
						if ($artistMenus{1}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS',
								'_BROWSEMENU_COLLECTED_ALLARTISTS',
								'artists',
								'html/images/artists.png',
								0,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										#'role_id:'.join ',', Slim::Schema::Contributor->contributorRoles()
									],
								}
							);
						}

						# Album artists
						if ($artistMenus{5}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS',
								'_BROWSEMENU_COLLECTED_ALBUMARTISTS',
								'artists',
								'html/images/artists.png',
								1,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:ALBUMARTIST'
									],
								}
							);
						}

						# Composers
						if ($artistMenus{2}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS',
								'_BROWSEMENU_COLLECTED_COMPOSERS',
								'artists',
								'html/images/artists.png',
								2,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:COMPOSER'
									],
								}
							);
						}

						# Conductors
						if ($artistMenus{3}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS',
								'_BROWSEMENU_COLLECTED_CONDUCTORS',
								'artists',
								'html/images/artists.png',
								3,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:CONDUCTOR'
									],
								}
							);
						}

						# Track Artists
						if ($artistMenus{6}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS',
								'_BROWSEMENU_COLLECTED_TRACKARTISTS',
								'artists',
								'html/images/artists.png',
								4,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:TRACKARTIST'
									],
								}
							);
						}

						# Bands
						if ($artistMenus{4}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS',
								'_BROWSEMENU_COLLECTED_BANDS',
								'artists',
								'html/images/artists.png',
								5,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:BAND'
									],
								}
							);
						}

						### ALBUMS MENUS ###

						# All albums
						if ($albumMenus{1}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS',
								'_BROWSEMENU_COLLECTED_ALLALBUMS',
								'albums',
								'html/images/albums.png',
								0,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}
							);
						}

						# All albums sorted by artist, year, album title
						if ($albumMenus{2}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM',
								'_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM',
								'albums',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
								1,
								{
									library_id => $pt->{'library_id'},
									'orderBy' => 'artflow',
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}
							);
						}

						# All albums sorted by year, album
						if ($albumMenus{9}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ALBUM',
								'_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_YEAR_ALBUM',
								'albums',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
								2,
								{
									library_id => $pt->{'library_id'},
									'orderBy' => 'yearalbum',
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}
							);
						}

						# All albums sorted by year, artist, album
						if ($albumMenus{10}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM',
								'_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM',
								'albums',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
								3,
								{
									library_id => $pt->{'library_id'},
									'orderBy' => 'yearartistalbum',
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}
							);
						}

						# All albums sorted by artist, album
						if ($albumMenus{11}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_ALBUM',
								'_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_ARTIST_ALBUM',
								'albums',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png',
								4,
								{
									library_id => $pt->{'library_id'},
									'orderBy' => 'artistalbum',
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}
							);
						}

						# Random Albums
						if ($albumMenus{3}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM',
								'_BROWSEMENU_COLLECTED_RANDOMALBUMS',
								'albums',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
								6,
								{
									library_id => $pt->{'library_id'},
									'mode' => 'randomalbums',
									'sort' => 'random',
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								},
								1
							);
						}

						# Albums without compilations
						if ($albumMenus{4}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS',
								'_BROWSEMENU_COLLECTED_NOCOMPIS',
								'albums',
								'html/images/albums.png',
								7,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'compilation: 0 || null',
									],
								}
							);
						}

						# Compilations only
						if ($albumMenus{5}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY',
								'_BROWSEMENU_COLLECTED_COMPISONLY',
								'albums',
								'html/images/albums.png',
								8,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'variousartistsid'},
										'compilation: 1',
									],
								}
							);
						}

						# Random compilations
						if ($albumMenus{6}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS',
								'_BROWSEMENU_COLLECTED_RANDOMCOMPIS',
								'albums',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
								9,
								{
									library_id => $pt->{'library_id'},
									'mode' => 'vaalbums',
									'sort' => 'random',
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'variousartistsid'},
										'compilation:1',
									],
								},
								1
							);
						}

						# Compilations by genre
						if ($albumMenus{7}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE',
								'_BROWSEMENU_COLLECTED_COMPISBYGENRE',
								'genres',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
								10,
								{
									library_id => $pt->{'library_id'},
									'mode' => 'vaalbums',
									'sort' => 'title',
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'variousartistsid'},
										'compilation:1',
									],
								}
							);
						}

						# Compilations by year
						if ($albumMenus{8}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR',
								'_BROWSEMENU_COLLECTED_COMPISBYYEAR',
								'years',
								'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png',
								11,
								{
									library_id => $pt->{'library_id'},
									'mode' => 'vaalbums',
									'sort' => 'title',
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'variousartistsid'},
										'compilation:1',
									],
								}
							);
						}

						### OTHER MENUS ###

						# Genres menu
						if ($miscMenus{1}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES',
								'_BROWSEMENU_COLLECTED_GENRE_ALL',
								'genres',
								'html/images/genres.png',
								12,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
									],
								}
							);
						}

						# Years menu
						if ($miscMenus{2}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS',
								'_BROWSEMENU_COLLECTED_YEARS',
								'years',
								'html/images/years.png',
								13,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
									],
								}
							);
						}

						# Tracks menu
						if ($miscMenus{3}) {
							push @collectedBrowseMenus, $menuGenerator->(
								'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS',
								'_BROWSEMENU_COLLECTED_TRACKS',
								'tracks',
								'html/images/playlists.png',
								14,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'sort:title'
									],
								}
							);
						}
					}

					$cb->({
						items => \@collectedBrowseMenus,
					});
				},
				weight => 99,
				cache => 0,
				icon => $iconPath,
				jiveIcon => $iconPath,
			});
		}

	main::INFOLOG && $log->is_info && $log->info('Finished initializing collected VL browse menus after '.(time() - $started).' secs.');
	}
}

sub deregAllMenus {
	my $nodeList = Slim::Menu::BrowseLibrary->_getNodeList();
	main::DEBUGLOG && $log->is_debug && $log->debug('node list = '.Data::Dump::dump($nodeList));

	foreach my $homeMenuItem (@{$nodeList}) {
		if (starts_with($homeMenuItem->{'id'}, 'PLUGIN_VLC_VL') == 0) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Deregistering home menu item: '.Data::Dump::dump($homeMenuItem->{'id'}));
			Slim::Menu::BrowseLibrary->deregisterNode($homeMenuItem->{'id'});
		}
	}
}

sub getVLCvirtualLibraryList {
	my $client = shift;

	my $itemConfiguration = getConfigManager()->readItemConfiguration($client, 1);
	$webVirtualLibraries = $itemConfiguration->{'webvirtuallibraries'};
	$virtualLibraries = $itemConfiguration->{'virtuallibraries'};

	main::DEBUGLOG && $log->is_debug && $log->debug('web virtual libraries = '.Data::Dump::dump($webVirtualLibraries));
	main::DEBUGLOG && $log->is_debug && $log->debug('virtual libraries = '.Data::Dump::dump($virtualLibraries));
}

sub setRefreshCBTimer {
	my $recreateChangedVL = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killTimers($recreateChangedVL, \&initVirtualLibrariesDelayed);
	main::DEBUGLOG && $log->is_debug && $log->debug('Scheduling a delayed'.($isPostScanCall ? ' post-scan' : '').' refresh');
	Slim::Utils::Timers::setTimer($recreateChangedVL, Time::HiRes::time() + $prefs->get('scheduledinitdelay'), \&initVirtualLibrariesDelayed);
}

sub initVirtualLibrariesDelayed {
	my $recreateChangedVL = shift;

	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Scan in progress. Waiting for current scan to finish.');
		setRefreshCBTimer();
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Starting delayed VL init');
		if ($isPostScanCall) { # If postscan call, only refresh cache & rebuild menus. VL reinit already happened in importer.
			refreshSQLCache();
			$isPostScanCall = 0;
		} else {
			initVirtualLibraries(undef, $recreateChangedVL);
		}
		initHomeVLMenus();
	}
}

sub getConfigManager {
	if (!defined($configManager)) {
		my %parameters = (
			'browseMenus' => \%browseMenus,
			'addSqlErrorCallback' => undef
		);
		$configManager = Plugins::VirtualLibraryCreator::ConfigManager::Main->new(\%parameters);
	}
	return $configManager;
}


### web pages

sub webPages {
	my %pages = (
		"VirtualLibraryCreator/list.html" => \&handleWebList,
		"VirtualLibraryCreator/webpagemethods_edititem.html" => \&handleWebEditVL,
		"VirtualLibraryCreator/webpagemethods_editcustomizeditem.html" => \&handleWebEditCustomizedVL,
		"VirtualLibraryCreator/webpagemethods_newitemtypes.html" => \&handleWebNewVLTypes,
		"VirtualLibraryCreator/webpagemethods_deleteitemtype.html" => \&handleWebDeleteVLType,
		"VirtualLibraryCreator/webpagemethods_newitemparameters.html" => \&handleWebNewVLParameters,
		"VirtualLibraryCreator/webpagemethods_savenewitem.html" => \&handleWebSaveNewVL,
		"VirtualLibraryCreator/webpagemethods_saveitem.html" => \&handleWebSaveVL,
		"VirtualLibraryCreator/webpagemethods_savecustomizeditem.html" => \&handleWebSaveCustomizedVL,
		"VirtualLibraryCreator/webpagemethods_removeitem.html" => \&handleWebRemoveVL,
		"VirtualLibraryCreator/webpagemethods_toggleenabledstate.html" => \&toggleTempDisabledState,
		"VirtualLibraryCreator/webpagemethods_manualrefresh.html" => \&manualglobalrefresh,
	);
	for my $page (keys %pages) {
		Slim::Web::Pages->addPageFunction($page, $pages{$page});
	}

	Slim::Web::Pages->addPageLinks("plugins", {'PLUGIN_VIRTUALLIBRARYCREATOR' => 'plugins/VirtualLibraryCreator/list.html'});
}

sub handleWebList {
	my ($client, $params) = @_;

	getVLCvirtualLibraryList($client);

	# Refresh/recreate virtual libraries ?
	main::DEBUGLOG && $log->is_debug && $log->debug('VL refresh required = '.Data::Dump::dump($params->{'vlrefresh'}));
	main::DEBUGLOG && $log->is_debug && $log->debug('New or edited VL = '.Data::Dump::dump($params->{'changedvl'}));

	setRefreshCBTimer($params->{'changedvl'}) if $params->{'vlrefresh'};

	# get VLs for web display
	my @webVLs = ();
	for my $key (keys %{$webVirtualLibraries}) {
		push @webVLs, $webVirtualLibraries->{$key};
	}
	@webVLs = sort {uc($a->{'name'}) cmp uc($b->{'name'})} @webVLs;
	main::DEBUGLOG && $log->is_debug && $log->debug('webVLs = '.Data::Dump::dump(\@webVLs));
	$params->{'pluginVirtualLibraryCreatorVLs'} = \@webVLs;

	# check custom folder
	my $dir = $prefs->get('customvirtuallibrariesfolder');
	if (!defined $dir || !-d $dir) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_MISSING_CUSTOMDIR');
		my $customVLFolder_parentfolderpath = $prefs->get('customdirparentfolderpath');
		$log->error("Could not create or access VirtualLibraryCreator folder in parent folder '$customVLFolder_parentfolderpath'! Please make sure that LMS has read/write permissions (755) for the (parent) folder.");
	}

	$params->{'displayhasbrowsemenus'} = $prefs->get('displayhasbrowsemenus');
	$params->{'displayisdailyrefreshed'} = $prefs->get('displayisdailyrefreshed');
	$params->{'globallydisabled'} = $prefs->get('vlstempdisabled');
	main::DEBUGLOG && $log->is_debug && $log->debug('VLS temp. disabled = '.Data::Dump::dump($params->{'globallydisabled'}));

	return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/list.html', $params);
}

sub handleWebEditVL {
	my ($client, $params) = @_;
	return getConfigManager()->webEditItem($client, $params);
}

sub handleWebEditCustomizedVL {
	my ($client, $params) = @_;
	return getConfigManager()->webEditCustomizedItem($client, $params);
}

sub handleWebNewVLTypes {
	my ($client, $params) = @_;
	return getConfigManager()->webNewItemTypes($client, $params);
}

sub handleWebNewVLParameters {
	my ($client, $params) = @_;
	return getConfigManager()->webNewItemParameters($client, $params);
}

sub handleWebVLlist {
	my ($client, $params) = @_;
	return getConfigManager()->webNewItem($client, $params);
}

sub handleWebSaveNewVL {
	my ($client, $params) = @_;
	return getConfigManager()->webSaveNewItem($client, $params);
}

sub handleWebSaveVL {
	my ($client, $params) = @_;
	return getConfigManager()->webSaveItem($client, $params);
}

sub handleWebSaveCustomizedVL {
	my ($client, $params) = @_;
	return getConfigManager()->webSaveCustomizedItem($client, $params);
}

sub handleWebRemoveVL {
	my ($client, $params) = @_;
	return getConfigManager()->webRemoveItem($client, $params);
}

sub toggleTempDisabledState {
	my ($client, $params) = @_;
	my $tmpDisabledState = $prefs->get('vlstempdisabled');
	main::DEBUGLOG && $log->is_debug && $log->debug('Current temp. disabled state = '.Data::Dump::dump($tmpDisabledState));

	$tmpDisabledState = $prefs->set('vlstempdisabled', ($tmpDisabledState ? 0 : 1));
	main::DEBUGLOG && $log->is_debug && $log->debug('New temp. disabled state = '.Data::Dump::dump($tmpDisabledState));
	$params->{'vlrefresh'} = 5; # 1 = all VLs temp. globally disabled/paused, 2 = new VL, 3 = edited VL, 4 = deleted VL, 5 = manual refresh
	handleWebList($client, $params);
}

sub manualglobalrefresh {
	my ($client, $params) = @_;
	$params->{'vlrefresh'} = 1; # 1 = all VLs temp. globally disabled/paused, 2 = new VL, 3 = edited VL, 4 = deleted VL, 5 = manual refresh
	$prefs->set('manualrefresh', 1);
	handleWebList($client, $params);
}

sub createVirtualLibrariesFolder {
	my $virtualLibrariesFolder_parentfolderpath = $prefs->get('customdirparentfolderpath') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $virtualLibrariesFolder = catdir($virtualLibrariesFolder_parentfolderpath, 'VirtualLibraryCreator');
	eval {
		mkdir($virtualLibrariesFolder, 0755) unless (-d $virtualLibrariesFolder);
	} or do {
		$log->error("Could not create VirtualLibraryCreator folder in parent folder '$virtualLibrariesFolder_parentfolderpath'!");
		return;
	};
	$prefs->set('customvirtuallibrariesfolder', $virtualLibrariesFolder);
}

sub getVirtualLibraries {
	my $curVLID = shift;
	my @items;

	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	main::DEBUGLOG && $log->is_debug && $log->debug('ALL virtual libraries: '.Data::Dump::dump($libraries));

	while (my ($key, $values) = each %{$libraries}) {
		my $count = Slim::Music::VirtualLibraries->getTrackCount($key);
		my $name = $values->{'name'};
		my $displayName = Slim::Utils::Unicode::utf8decode($name, 'utf8').' ('.Slim::Utils::Misc::delimitThousands($count).($count == 1 ? ' track' : ' tracks').')';
		main::DEBUGLOG && $log->is_debug && $log->debug("VL: ".$displayName);
		my $persistentVLID = $values->{'id'};

		push @items, {
			name => $displayName,
			sortName => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
			value => $persistentVLID,
			id => $persistentVLID,
		} unless $curVLID && $persistentVLID eq $curVLID;
	}
	if (scalar @items == 0) {
		push @items, {
			name => 'No virtual libraries found',
			value => '',
			id => '',
		};
	}

	if (scalar @items > 1) {
		@items = sort {lc($a->{sortName}) cmp lc($b->{sortName})} @items;
	}
	return \@items;
}

sub getVLBrowseMenus {
	my $type = shift;
	my @result = ();
	if (!$prefs->get('allbrowsemenus_tmpdisabled') && $type) {
		my $requestedMenus = $browseMenus{$type};
		for my $menu (sort { ($requestedMenus->{$a}->{'sortval'} || 0) <=> ($requestedMenus->{$b}->{'sortval'} || 0)} keys %{$requestedMenus}) {
			my %item = (
				'id' => $menu,
				'name' => $requestedMenus->{$menu}->{'name'},
				'value' => $menu
			);
			push @result, \%item;
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('getVLBrowseMenus result = '.Data::Dump::dump(\@result));
	return \@result;
}

sub getVLBrowseMenusArtists {
	return getVLBrowseMenus('artists');
}

sub getVLBrowseMenusAlbums {
	return getVLBrowseMenus('albums');
}

sub getVLBrowseMenusMisc {
	return getVLBrowseMenus('misc');
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub registerCustomString {
	my $string = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('string = '.Data::Dump::dump($string));

	if (!Slim::Utils::Strings::stringExists($string)) {
		my $token = uc(Slim::Utils::Text::ignoreCase($string, 1));
		$token =~ s/\s/_/g;
		$token = 'PLUGIN_VLC_BROWSEMENUS_' . $token;
		Slim::Utils::Strings::storeExtraStrings([{
			strings => {EN => $string},
			token => $token,
		}]) if !Slim::Utils::Strings::stringExists($token);
		return $token;
	}
	return $string;
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}

sub refreshSQLCache {
	main::DEBUGLOG && $log->is_debug && $log->debug('Deleting old caches and creating new ones');
	$cache->remove('vlc_pluginversion');
	$cache->remove('vlc_contributorlist_all');
	$cache->remove('vlc_contributorlist_albumartists');
	$cache->remove('vlc_contributorlist_composers');
	$cache->remove('vlc_genrelist');
	$cache->remove('vlc_contenttypes');
	$cache->remove('vlc_releasetypes');

	my $contributorSQL_all = "select contributors.id,contributors.name,contributors.namesearch from tracks,contributor_track,contributors where tracks.id=contributor_track.track and contributor_track.contributor=contributors.id and contributor_track.role in (1,5,6) group by contributors.id order by contributors.namesort asc";
	my $contributorSQL_albumartists = "select contributors.id,contributors.name,contributors.namesearch from tracks,contributor_track,contributors where tracks.id=contributor_track.track and contributor_track.contributor=contributors.id and contributor_track.role in (1,5) group by contributors.id order by contributors.namesort asc";
	my $contributorSQL_composers = "select contributors.id,contributors.name,contributors.namesearch from tracks,contributor_track,contributors where tracks.id=contributor_track.track and contributor_track.contributor=contributors.id and contributor_track.role = 2 group by contributors.id order by contributors.namesort asc";
	my $genreSQL = "select genres.id,genres.name,genres.namesearch from genres order by namesort asc";
	my $contentTypesSQL = "select distinct tracks.content_type,tracks.content_type,tracks.content_type from tracks where tracks.content_type is not null and tracks.content_type != 'cpl' and tracks.content_type != 'src' and tracks.content_type != 'ssp' and tracks.content_type != 'dir' order by tracks.content_type asc";
	my $releaseTypesSQL = "select distinct albums.release_type,albums.release_type,albums.release_type from albums order by albums.release_type asc";

	my $contributorList_all = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contributorSQL_all);
	$cache->set('vlc_contributorlist_all', $contributorList_all, 'never');
	main::DEBUGLOG && $log->is_debug && $log->debug('contributorList_all count = '.scalar(@{$contributorList_all}));

	my $contributorList_albumartists = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contributorSQL_albumartists);
	$cache->set('vlc_contributorlist_albumartists', $contributorList_albumartists, 'never');
	main::DEBUGLOG && $log->is_debug && $log->debug('contributorList_albumartists count = '.scalar(@{$contributorList_albumartists}));

	my $contributorList_composers = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contributorSQL_composers);
	$cache->set('vlc_contributorlist_composers', $contributorList_composers, 'never');
	main::DEBUGLOG && $log->is_debug && $log->debug('contributorList_composers count = '.scalar(@{$contributorList_composers}));

	my $genreList = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $genreSQL);
	$cache->set('vlc_genrelist', $genreList, 'never');
	main::DEBUGLOG && $log->is_debug && $log->debug('genreList count = '.scalar(@{$genreList}));

	my $contentTypesList = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contentTypesSQL);
	$cache->set('vlc_contenttypes', $contentTypesList, 'never');
	main::DEBUGLOG && $log->is_debug && $log->debug('contentTypesList count = '.scalar(@{$contentTypesList}));

	my $releaseTypesList = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $releaseTypesSQL);
	foreach my $releaseType (@{$releaseTypesList}) {
		$releaseType->{'name'} = _releaseTypeName($releaseType->{'name'});
	}
	$cache->set('vlc_releasetypes', $releaseTypesList, 'never');
	main::DEBUGLOG && $log->is_debug && $log->debug('releaseTypesList count = '.scalar(@{$releaseTypesList}));

	$cache->set('vlc_pluginversion', $pluginVersion);
}

sub _releaseTypeName {
	my $releaseType = shift;

	my $nameToken = uc($releaseType);
	$nameToken =~ s/[^a-z_0-9]/_/ig;
	my $name;
	foreach ('RELEASE_TYPE_' . $nameToken, 'RELEASE_TYPE_CUSTOM_' . $nameToken, $nameToken) {
		$name = string($_) if Slim::Utils::Strings::stringExists($_);
		last if $name;
	}
	return $name || $releaseType;
}

1;
