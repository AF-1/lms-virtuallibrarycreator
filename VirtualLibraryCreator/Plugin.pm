#
# Virtual Library Creator
# (c) 2023 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::VirtualLibraryCreator::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use File::Slurp qw(read_file);
use File::Spec::Functions qw(catdir catfile);
use HTML::Entities qw(encode_entities decode_entities);
use Time::Local qw(timelocal);
use XML::Simple qw(XMLin);

use Plugins::VirtualLibraryCreator::Common ':all';
use Plugins::VirtualLibraryCreator::Importer;
use constant SCHEDULED_INIT_DELAY => 10;

my $prefs = preferences('plugin.virtuallibrarycreator');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.virtuallibrarycreator',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_VIRTUALLIBRARYCREATOR',
});
my $pluginVersion;
my $items; # cached virtual library item configurations
my $templateHandler; # Template Toolkit object, created on first use
my $isPostScanCall = 0;
my %browseMenus = ();
my $unsafeChars = "&<>'\"";
my %largeFields = map {$_ => 50} qw(virtuallibraryname albumsearchtitle1 albumsearchtitle2 albumsearchtitle3 tracksearchtitle1 tracksearchtitle2 tracksearchtitle3 filepath1 filepath2 filepath3);
my %mediumFields = map {$_ => 35} qw(commentssearchstring1 commentssearchstring2 commentssearchstring3);
my %smallFields = map {$_ => 5} qw(nooftracks noofartists noofalbums noofgenres noofyears minlength maxlength minyear maxyear minartisttracks minalbumtracks mingenretracks minplaylisttracks minyeartracks minbitrate maxbitrate minsamplerate maxsamplerate minsamplesize maxsamplesize minbpm maxbpm skipcount maxskipcount browsemenusartistshomemenuweight browsemenusalbumshomemenuweight browsemenusmischomemenuweight libraryinitorder);

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	$pluginVersion = Slim::Utils::PluginManager->dataForPlugin($class)->{'version'};

	initPrefs();

	if (main::WEBUI) {
		require Plugins::VirtualLibraryCreator::Settings;
		Plugins::VirtualLibraryCreator::Settings->new($class);
		_getTemplates();
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

	%browseMenus = (
		'artists' => {
			1 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS'), 'sortval' => 1},
			5 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS'), 'sortval' => 2},
			2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS'), 'sortval' => 3},
			3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS'), 'sortval' => 4},
			6 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS'), 'sortval' => 5},
			4 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS'), 'sortval' => 6},
		},
		'albums' => {
			1 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS'), 'sortval' => 1},
			2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM'), 'sortval' => 2},
			9 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ALBUM'), 'sortval' => 3},
			10 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM'), 'sortval' => 4},
			11 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_ALBUM'), 'sortval' => 5},
			3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM'), 'sortval' => 7},
			4 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS'), 'sortval' => 8},
			5 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY'), 'sortval' => 9},
			6 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS'), 'sortval' => 10},
			7 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE'), 'sortval' => 11},
			8 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR'), 'sortval' => 12},
		},
		'misc' => {
			1 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES'), 'sortval' => 1},
			2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS'), 'sortval' => 2},
			3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS'), 'sortval' => 3},
		},
	);
}

sub postinitPlugin {
	my $class = shift;
	return unless Slim::Schema::hasLibrary() && !Slim::Music::Import->stillScanning;
	initVirtualLibrariesDelayed();
}

sub initHomeVLMenus {
	main::DEBUGLOG && $log->is_debug && $log->debug('Started initializing HOME VL menus.');
	my $started = time();

	deregAllMenus();
	getVLCvirtualLibraryList();

	if (keys %{$items} > 0) {
		my @enabledHomeBrowseMenus = grep {
			$items->{$_}{'enabled'} &&
			Slim::Music::VirtualLibraries->getRealId($items->{$_}{'VLID'}) &&
			(($items->{$_}{'artistmenus'} && $items->{$_}{'artistmenushomemenu'}) ||
			($items->{$_}{'albummenus'} && $items->{$_}{'albummenushomemenu'}) ||
			($items->{$_}{'miscmenus'} && $items->{$_}{'miscmenushomemenu'}))
		} keys %{$items};

		main::DEBUGLOG && $log->is_debug && $log->debug('enabled home menu browse menus = '.scalar(@enabledHomeBrowseMenus)."\n".Data::Dump::dump(\@enabledHomeBrowseMenus));

		if (@enabledHomeBrowseMenus) {
			my @homeBrowseMenus = ();

			for my $key (sort @enabledHomeBrowseMenus) {
				my $vl = $items->{$key};
				next unless $vl->{'enabled'};
				my $library_id = Slim::Music::VirtualLibraries->getRealId($vl->{'VLID'});
				next unless $library_id;

				my $browsemenu_name = $vl->{'name'};
				my %artistMenus = $vl->{'artistmenus'} && $vl->{'artistmenushomemenu'} ? map {$_ => 1} split(/,/, $vl->{'artistmenus'}) : ();
				my %albumMenus = $vl->{'albummenus'} && $vl->{'albummenushomemenu'} ? map {$_ => 1} split(/,/, $vl->{'albummenus'}) : ();
				my %miscMenus = $vl->{'miscmenus'} && $vl->{'miscmenushomemenu'} ? map {$_ => 1} split(/,/, $vl->{'miscmenus'}) : ();
				my $artistWeight = $vl->{'artistmenushomemenuweight'};
				my $albumWeight = $vl->{'albummenushomemenuweight'};
				my $miscWeight = $vl->{'miscmenushomemenuweight'};
				my $VLID = $vl->{'VLID'};

				my $menuGenerator = sub {
					my ($menuStringToken, $id, $feed, $icon, $offset, $params, $isRandom) = @_;

					my $menuString = registerCustomString("$browsemenu_name - " . string($menuStringToken));
					my $homeMenusWeight = 209 + $offset;

					if ($feed eq 'artists') {
						$feed = \&Slim::Menu::BrowseLibrary::_artists;
						$homeMenusWeight = $artistWeight + $offset if $artistWeight;
						if ($menuStringToken eq 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS_HOMEDISPLAYED') {
							$menuString = registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS_HOMEDISPLAYED'));
							$homeMenusWeight = 12;
						}
					} elsif ($feed eq 'genres') {
						$feed = \&Slim::Menu::BrowseLibrary::_genres;
						$homeMenusWeight = $miscWeight + $offset if $miscWeight;
						if ($menuStringToken eq 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED') {
							$menuString = registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED'));
							$homeMenusWeight = 24;
						}
					} elsif ($feed eq 'years') {
						$feed = \&Slim::Menu::BrowseLibrary::_years;
						$homeMenusWeight = $miscWeight + $offset if $miscWeight;
					} elsif ($feed eq 'tracks') {
						$feed = \&Slim::Menu::BrowseLibrary::_tracks;
						$homeMenusWeight = $miscWeight + $offset if $miscWeight;
					} else {
						$feed = \&Slim::Menu::BrowseLibrary::_albums;
						$homeMenusWeight = $albumWeight + $offset if $albumWeight;
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
						cache => $isRandom ? 0 : 1,
						feed => $feed,
						params => $params,
					};
				};

				### ARTIST MENUS ###
				if ($artistMenus{1}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS', '_BROWSEMENU_ALLARTISTS', 'artists', 'html/images/artists.png', 0, {library_id => $library_id});
				}
				if ($artistMenus{5}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS', '_BROWSEMENU_ALBUMARTISTS', 'artists', 'html/images/artists.png', 1, {library_id => $library_id, role_id => 'ALBUMARTIST'});
				}
				if ($artistMenus{2}) {
					my $tok = lc($browsemenu_name) eq 'composers' ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS_HOMEDISPLAYED' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS';
					push @homeBrowseMenus, $menuGenerator->($tok, '_BROWSEMENU_COMPOSERS', 'artists', 'html/images/artists.png', 2, {library_id => $library_id, role_id => 'COMPOSER'});
				}
				if ($artistMenus{3}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS', '_BROWSEMENU_CONDUCTORS', 'artists', 'html/images/artists.png', 3, {library_id => $library_id, role_id => 'CONDUCTOR'});
				}
				if ($artistMenus{6}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS', '_BROWSEMENU_TRACKARTISTS', 'artists', 'html/images/artists.png', 4, {library_id => $library_id, role_id => 'TRACKARTIST'});
				}
				if ($artistMenus{4}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS', '_BROWSEMENU_BANDS', 'artists', 'html/images/artists.png', 5, {library_id => $library_id, role_id => 'BAND'});
				}

				### ALBUM MENUS ###
				if ($albumMenus{1}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS', '_BROWSEMENU_HOME_ALLALBUMS', 'albums', 'html/images/albums.png', 6, {library_id => $library_id});
				}
				if ($albumMenus{2}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM', '_BROWSEMENU_HOME_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 7, {library_id => $library_id, 'orderBy' => 'artflow'});
				}
				if ($albumMenus{9}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ALBUM', '_BROWSEMENU_HOME_ALLALBUMS_SORTED_YEAR_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 8, {library_id => $library_id, 'orderBy' => 'yearalbum'});
				}
				if ($albumMenus{10}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM', '_BROWSEMENU_HOME_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 9, {library_id => $library_id, 'orderBy' => 'yearartistalbum'});
				}
				if ($albumMenus{11}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_ALBUM', '_BROWSEMENU_HOME_ALLALBUMS_SORTED_ARTIST_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 10, {library_id => $library_id, 'orderBy' => 'artistalbum'});
				}
				if ($albumMenus{3}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM', '_BROWSEMENU_HOME_RANDOMALBUMS', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png', 12, {library_id => $library_id, mode => 'randomalbums', sort => 'random'}, 1);
				}
				if ($albumMenus{5}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY', '_BROWSEMENU_HOME_COMPISONLY', 'albums', 'html/images/albums.png', 14, {library_id => $library_id, artist_id => Slim::Schema->variousArtistsObject->id, mode => 'vaalbums', compilation => 1});
				}
				if ($albumMenus{6}) {
					my $tok = lc($browsemenu_name) eq 'compilations random' ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS_HOMEDISPLAYED' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS';
					push @homeBrowseMenus, $menuGenerator->($tok, '_BROWSEMENU_HOME_RANDOMCOMPIS', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png', 15, {library_id => $library_id, artist_id => Slim::Schema->variousArtistsObject->id, mode => 'randomalbums', sort => 'random', compilation => 1}, 1);
				}
				if ($albumMenus{7}) {
					my $tok = lc($browsemenu_name) eq 'compilations by genre' ? 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED' : 'PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE';
					push @homeBrowseMenus, $menuGenerator->($tok, '_BROWSEMENU_HOME_COMPISBYGENRE', 'genres', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png', 16, {library_id => $library_id, artist_id => Slim::Schema->variousArtistsObject->id, mode => 'genres', sort => 'title', compilation => 1});
				}
				if ($albumMenus{8}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR', '_BROWSEMENU_HOME_COMPISBYYEAR', 'years', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png', 17, {library_id => $library_id, artist_id => Slim::Schema->variousArtistsObject->id, mode => 'years', sort => 'title', compilation => 1});
				}

				### MISC MENUS ###
				if ($miscMenus{1}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES', '_BROWSEMENU_GENRE_ALL', 'genres', 'html/images/genres.png', 18, {library_id => $library_id});
				}
				if ($miscMenus{2}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS', '_BROWSEMENU_YEARS', 'years', 'html/images/years.png', 19, {library_id => $library_id});
				}
				if ($miscMenus{3}) {
					push @homeBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS', '_BROWSEMENU_TRACKS', 'tracks', 'html/images/playlists.png', 20, {library_id => $library_id, sort => 'title'});
				}
			}

			for (@homeBrowseMenus) {
				Slim::Menu::BrowseLibrary->deregisterNode($_);
				Slim::Menu::BrowseLibrary->registerNode($_);
			}
		}
	}

	main::INFOLOG && $log->is_info && $log->info('Finished initializing home VL browse menus after '.(time() - $started).' secs.');
	initCollectedVLMenus();
}

sub initCollectedVLMenus {
	main::DEBUGLOG && $log->is_debug && $log->debug('Started initializing collected VL menus.');
	my $started = time();

	my $browsemenus_parentfolderID = 'PLUGIN_VLC_VLCPARENTFOLDER';
	my $browsemenus_parentfoldername = $prefs->get('browsemenus_parentfoldername') || 'My VLC Menus';

	Slim::Menu::BrowseLibrary->deregisterNode($browsemenus_parentfolderID);
	my $nameToken = registerCustomString($browsemenus_parentfoldername);

	if (keys %{$items} > 0) {
		my @enabledCollectedBrowseMenus = grep {
			$items->{$_}{'enabled'} &&
			Slim::Music::VirtualLibraries->getRealId($items->{$_}{'VLID'}) &&
			(($items->{$_}{'artistmenus'} && !$items->{$_}{'artistmenushomemenu'}) ||
			($items->{$_}{'albummenus'} && !$items->{$_}{'albummenushomemenu'}) ||
			($items->{$_}{'miscmenus'} && !$items->{$_}{'miscmenushomemenu'}))
		} keys %{$items};

		main::DEBUGLOG && $log->is_debug && $log->debug('enabled browse menus collected in VLC parent folder = '.scalar(@enabledCollectedBrowseMenus)."\n".Data::Dump::dump(\@enabledCollectedBrowseMenus));

		if (@enabledCollectedBrowseMenus) {
			my $browsemenus_parentfoldericon = $prefs->get('browsemenus_parentfoldericon');
			my $iconPath = $browsemenus_parentfoldericon == 1 ? 'plugins/VirtualLibraryCreator/html/images/parentfolder-browsemenuicon.png'
			: $browsemenus_parentfoldericon == 2 ? 'plugins/VirtualLibraryCreator/html/images/parentfolder-folder_svg.png'
			: 'plugins/VirtualLibraryCreator/html/images/parentfolder-music_svg.png';

			Slim::Menu::BrowseLibrary->registerNode({
				type => 'link',
				name => $nameToken,
				id => $browsemenus_parentfolderID,
				feed => sub {
					my ($client, $cb, $args, $pt) = @_;
					my @collectedBrowseMenus = ();

					for my $key (sort @enabledCollectedBrowseMenus) {
						my $vl = $items->{$key};
						my $VLID = $vl->{'VLID'};
						my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
						my $browsemenu_name = $vl->{'name'};
						my $variousartistsid = Slim::Schema->variousArtistsObject->id;
						main::DEBUGLOG && $log->is_debug && $log->debug('browsemenu_name = '.$browsemenu_name);

						my %artistMenus = $vl->{'artistmenus'} && !$vl->{'artistmenushomemenu'} ? map {$_ => 1} split(/,/, $vl->{'artistmenus'}) : ();
						my %albumMenus = $vl->{'albummenus'} && !$vl->{'albummenushomemenu'} ? map {$_ => 1} split(/,/, $vl->{'albummenus'}) : ();
						my %miscMenus = $vl->{'miscmenus'} && !$vl->{'miscmenushomemenu'} ? map {$_ => 1} split(/,/, $vl->{'miscmenus'}) : ();

						my $menuGenerator = sub {
							my ($menuStringToken, $id, $feed, $icon, $offset, $params, $isRandom) = @_;
							$feed = $feed eq 'artists' ? \&Slim::Menu::BrowseLibrary::_artists
							: $feed eq 'genres' ? \&Slim::Menu::BrowseLibrary::_genres
							: $feed eq 'years' ? \&Slim::Menu::BrowseLibrary::_years
							: $feed eq 'tracks' ? \&Slim::Menu::BrowseLibrary::_tracks
							: \&Slim::Menu::BrowseLibrary::_albums;
							return {
								type => 'link',
								name => $browsemenu_name.' - '.string($menuStringToken),
								icon => $icon,
								jiveIcon => $icon,
								id => $VLID . $id,
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 209 + $offset,
								cache => $isRandom ? 0 : 1,
								url => $feed,
								passthrough => [$params],
							};
						};

						### ARTIST MENUS ###
						if ($artistMenus{1}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS', '_BROWSEMENU_COLLECTED_ALLARTISTS', 'artists', 'html/images/artists.png', 0, {library_id => $library_id, searchTags => ['library_id:'.$library_id]});
						}
						if ($artistMenus{5}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS', '_BROWSEMENU_COLLECTED_ALBUMARTISTS', 'artists', 'html/images/artists.png', 1, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'role_id:ALBUMARTIST']});
						}
						if ($artistMenus{2}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS', '_BROWSEMENU_COLLECTED_COMPOSERS', 'artists', 'html/images/artists.png', 2, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'role_id:COMPOSER']});
						}
						if ($artistMenus{3}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS', '_BROWSEMENU_COLLECTED_CONDUCTORS', 'artists', 'html/images/artists.png', 3, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'role_id:CONDUCTOR']});
						}
						if ($artistMenus{6}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS', '_BROWSEMENU_COLLECTED_TRACKARTISTS', 'artists', 'html/images/artists.png', 4, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'role_id:TRACKARTIST']});
						}
						if ($artistMenus{4}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS', '_BROWSEMENU_COLLECTED_BANDS', 'artists', 'html/images/artists.png', 5, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'role_id:BAND']});
						}

						### ALBUM MENUS ###
						if ($albumMenus{1}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS', '_BROWSEMENU_COLLECTED_ALLALBUMS', 'albums', 'html/images/albums.png', 0, {library_id => $library_id, searchTags => ['library_id:'.$library_id]});
						}
						if ($albumMenus{2}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM', '_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_ARTIST_YEAR_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 1, {library_id => $library_id, 'orderBy' => 'artflow', searchTags => ['library_id:'.$library_id]});
						}
						if ($albumMenus{9}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ALBUM', '_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_YEAR_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 2, {library_id => $library_id, 'orderBy' => 'yearalbum', searchTags => ['library_id:'.$library_id]});
						}
						if ($albumMenus{10}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM', '_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_YEAR_ARTIST_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 3, {library_id => $library_id, 'orderBy' => 'yearartistalbum', searchTags => ['library_id:'.$library_id]});
						}
						if ($albumMenus{11}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS_SORTED_ARTIST_ALBUM', '_BROWSEMENU_COLLECTED_ALLALBUMS_SORTED_ARTIST_ALBUM', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumssorted_svg.png', 4, {library_id => $library_id, 'orderBy' => 'artistalbum', searchTags => ['library_id:'.$library_id]});
						}
						if ($albumMenus{3}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM', '_BROWSEMENU_COLLECTED_RANDOMALBUMS', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png', 6, {library_id => $library_id, 'mode' => 'randomalbums', 'sort' => 'random', searchTags => ['library_id:'.$library_id]}, 1);
						}
						if ($albumMenus{4}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS', '_BROWSEMENU_COLLECTED_NOCOMPIS', 'albums', 'html/images/albums.png', 7, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'compilation: 0 || null']});
						}
						if ($albumMenus{5}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY', '_BROWSEMENU_COLLECTED_COMPISONLY', 'albums', 'html/images/albums.png', 8, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'artist_id:'.$variousartistsid, 'compilation: 1']});
						}
						if ($albumMenus{6}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS', '_BROWSEMENU_COLLECTED_RANDOMCOMPIS', 'albums', 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png', 9, {library_id => $library_id, 'mode' => 'vaalbums', 'sort' => 'random', searchTags => ['library_id:'.$library_id, 'artist_id:'.$variousartistsid, 'compilation:1']}, 1);
						}
						if ($albumMenus{7}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE', '_BROWSEMENU_COLLECTED_COMPISBYGENRE', 'genres', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png', 10, {library_id => $library_id, 'mode' => 'vaalbums', 'sort' => 'title', searchTags => ['library_id:'.$library_id, 'artist_id:'.$variousartistsid, 'compilation:1']});
						}
						if ($albumMenus{8}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR', '_BROWSEMENU_COLLECTED_COMPISBYYEAR', 'years', 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png', 11, {library_id => $library_id, 'mode' => 'vaalbums', 'sort' => 'title', searchTags => ['library_id:'.$library_id, 'artist_id:'.$variousartistsid, 'compilation:1']});
						}

						### MISC MENUS ###
						if ($miscMenus{1}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES', '_BROWSEMENU_COLLECTED_GENRE_ALL', 'genres', 'html/images/genres.png', 12, {library_id => $library_id, searchTags => ['library_id:'.$library_id]});
						}
						if ($miscMenus{2}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS', '_BROWSEMENU_COLLECTED_YEARS', 'years', 'html/images/years.png', 13, {library_id => $library_id, searchTags => ['library_id:'.$library_id]});
						}
						if ($miscMenus{3}) {
							push @collectedBrowseMenus, $menuGenerator->('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS', '_BROWSEMENU_COLLECTED_TRACKS', 'tracks', 'html/images/playlists.png', 14, {library_id => $library_id, searchTags => ['library_id:'.$library_id, 'sort:title']});
						}
					}
					$cb->({items => \@collectedBrowseMenus});
				},
				weight => 99,
				cache => 0,
				icon => $iconPath,
				jiveIcon => $iconPath,
			});
		}
	}

	main::INFOLOG && $log->is_info && $log->info('Finished initializing collected VL browse menus after '.(time() - $started).' secs.');
}

sub deregAllMenus {
	my $nodeList = Slim::Menu::BrowseLibrary->_getNodeList();
	main::DEBUGLOG && $log->is_debug && $log->debug('node list = '.Data::Dump::dump($nodeList));
	for my $homeMenuItem (@{$nodeList}) {
		if (starts_with($homeMenuItem->{'id'}, 'PLUGIN_VLC_VL') == 0) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Deregistering home menu item: '.Data::Dump::dump($homeMenuItem->{'id'}));
			Slim::Menu::BrowseLibrary->deregisterNode($homeMenuItem->{'id'});
		}
	}
}

sub getVLCvirtualLibraryList {
	my $client = shift;
	my $itemConfiguration = readItemConfiguration($client);
	$items = $itemConfiguration->{'webvirtuallibraries'};
	main::DEBUGLOG && $log->is_debug && $log->debug('virtual libraries = '.Data::Dump::dump($items));
}

sub setRefreshCBTimer {
	my $recreateChangedVL = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killTimers($recreateChangedVL, \&initVirtualLibrariesDelayed);
	main::DEBUGLOG && $log->is_debug && $log->debug('Scheduling a delayed'.($isPostScanCall ? ' post-scan' : '').' refresh');
	Slim::Utils::Timers::setTimer($recreateChangedVL, Time::HiRes::time() + SCHEDULED_INIT_DELAY, \&initVirtualLibrariesDelayed);
}

sub initVirtualLibrariesDelayed {
	my $recreateChangedVL = shift;
	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Scan in progress. Waiting for current scan to finish.');
		setRefreshCBTimer();
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Starting delayed VL init');
		if ($isPostScanCall) {
			$isPostScanCall = 0;
		} else {
			initVirtualLibraries(undef, $recreateChangedVL);
		}
		initHomeVLMenus();
	}
}



### web pages

sub webPages {
	my %pages = (
		"VirtualLibraryCreator/list.html" => \&handleWebList,
		"VirtualLibraryCreator/webpagemethods_edititem.html" => \&handleWebEditVL,
		"VirtualLibraryCreator/webpagemethods_editcustomizeditem.html" => \&handleWebEditCustomizedVL,
		"VirtualLibraryCreator/webpagemethods_newitemtypes.html" => \&handleWebNewVLTypes,
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

	main::DEBUGLOG && $log->is_debug && $log->debug('VL refresh required = '.Data::Dump::dump($params->{'vlrefresh'}));
	main::DEBUGLOG && $log->is_debug && $log->debug('New or edited VL = '.Data::Dump::dump($params->{'changedvl'}));
	setRefreshCBTimer($params->{'changedvl'}) if $params->{'vlrefresh'};

	my @webVLs = sort {uc($a->{'name'}) cmp uc($b->{'name'})} values %{$items};
	main::DEBUGLOG && $log->is_debug && $log->debug('webVLs = '.Data::Dump::dump(\@webVLs));
	$params->{'pluginVirtualLibraryCreatorVLs'} = \@webVLs;

	my $dir = $prefs->get('customvirtuallibrariesfolder');
	if (!defined $dir || !-d $dir) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_MISSING_CUSTOMDIR');
		$log->error("Could not create or access VirtualLibraryCreator folder in parent folder '".$prefs->get('customdirparentfolderpath')."'! Please make sure that LMS has read/write permissions (755) for the (parent) folder.");
	}

	$params->{'displayhasbrowsemenus'} = $prefs->get('displayhasbrowsemenus');
	$params->{'displayisdailyrefreshed'} = $prefs->get('displayisdailyrefreshed');
	$params->{'globallydisabled'} = $prefs->get('vlstempdisabled');
	main::DEBUGLOG && $log->is_debug && $log->debug('VLS temp. disabled = '.Data::Dump::dump($params->{'globallydisabled'}));

	return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/list.html', $params);
}

sub handleWebEditVL {
	my ($client, $params) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('Start handleWebEditVL');

	$items = readItemConfiguration($client)->{'webvirtuallibraries'} unless defined($items);
	my $itemId = $params->{'item'};

	if (defined($itemId) && defined($items->{$itemId})) {
		$params->{'pluginWebPageMethodsEditVLwasEnabledBefore'} = $items->{$itemId}{'enabled'};
		my $templateData = _loadTemplateValues($itemId);

		if (defined($templateData)) {
			my $template = _getTemplates()->{lc($templateData->{'id'})};

			if (defined($template)) {
				my %currentParameterValues = ();
				my $vlTemplateVersion = $templateData->{'templateversion'} || 0;

				for my $p (@{$templateData->{'parameter'}}) {
					my $values = $p->{'value'};

					$values = [$p->{'content'}] if !defined($values) && defined($p->{'content'});
					my %valuesHash = map {$_ => $_} grep {ref($_) ne 'HASH'} @{$values || []};
					$valuesHash{''} = '' unless %valuesHash;
					$currentParameterValues{$p->{'id'}} = \%valuesHash;
				}

				my @parametersToSelect = ();
				for my $p (@{_getUsableParameters($template)}) {
					if (!defined($currentParameterValues{$p->{'id'}})) {
						my $value = $p->{'value'};
						$currentParameterValues{$p->{'id'}} = {$value => $value} if defined($value) && ref($value) ne 'HASH';
					}

					my $field = buildParameterFormField($p, $currentParameterValues{$p->{'id'}});

					if ($p->{'id'} eq 'virtuallibraryname') {
						$field->{'basetemplate'} = $template->{'name'};
						$field->{'templateversion'} = $template->{'templateversion'};
						main::DEBUGLOG && $log->is_debug && $log->debug('new template version: '.Data::Dump::dump($field->{'templateversion'}));
						$field->{'vltemplateversion'} = $vlTemplateVersion;
						main::DEBUGLOG && $log->is_debug && $log->debug('template version of virtual library: '.Data::Dump::dump($field->{'vltemplateversion'}));
						$field->{'vlid'} = $items->{$itemId}{'VLID'} if $prefs->get('displayvlids');
					}

					push @parametersToSelect, $field;
				}

				$params->{'pluginWebPageMethodsEditItemParameters'} = \@parametersToSelect;
				_setCustomTagInfo($params);
				$params->{'pluginWebPageMethodsEditItemTemplate'} = lc($templateData->{'id'});
				$params->{'pluginWebPageMethodsEditItemFile'} = $itemId;
				$params->{'pluginWebPageMethodsEditItemFileUnescaped'} = unescape($itemId);
				return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/webpagemethods_edititem.html', $params);
			}
		}
	}
	return handleWebList($client, $params);
}

sub handleWebEditCustomizedVL {
	my ($client, $params) = @_;

	$items = readItemConfiguration($client)->{'webvirtuallibraries'} unless defined($items);
	my $itemId = $params->{'item'};
	my $homeMenuDefaultWeight = 110;

	if (defined($itemId) && defined($items->{$itemId}) && defined($items->{$itemId}{'external'})) {
		my $vl = $items->{$itemId};
		$params->{'pluginWebPageMethodsEditItemName'} = $vl->{'name'};
		$params->{'pluginWebPageMethodsEditItemID'} = $vl->{'id'};
		$params->{'pluginWebPageMethodsEditVLID'} = $vl->{'VLID'} if $prefs->get('displayvlids');
		$params->{'enabled'} = $params->{'pluginWebPageMethodsEditVLwasEnabledBefore'} = $vl->{'enabled'} || 0;
		$params->{'dailyvlrefresh'} = $vl->{'dailyvlrefresh'} || 0;
		$params->{'libraryinitorder'} = $vl->{'libraryinitorder'} || 50;

		for my $menuType (['artists', 'browsemenusartists', $homeMenuDefaultWeight],
		['albums', 'browsemenusalbums', $homeMenuDefaultWeight + 10],
		['misc', 'browsemenusmisc', $homeMenuDefaultWeight + 20]) {
			my ($type, $paramkey, $defaultWeight) = @{$menuType};
			my $menuField = $type eq 'artists' ? 'artistmenus' : $type eq 'albums' ? 'albummenus' : 'miscmenus';
			my $homeMenuField = $type eq 'artists' ? 'artistmenushomemenu' : $type eq 'albums' ? 'albummenushomemenu' : 'miscmenushomemenu';
			my $weightField = $type eq 'artists' ? 'artistmenushomemenuweight' : $type eq 'albums' ? 'albummenushomemenuweight' : 'miscmenushomemenuweight';

			my %selectedMenus = $vl->{$menuField} ? map {$_ => 1} split(/,/, $vl->{$menuField}) : ();
			my @menuValues = ();
			for my $menu (sort { ($browseMenus{$type}{$a}{'sortval'} || 0) <=> ($browseMenus{$type}{$b}{'sortval'} || 0) } keys %{$browseMenus{$type}}) {
				push @menuValues, {
					'id' => $menu, 'name' => $browseMenus{$type}{$menu}{'name'},
					'value' => 1, 'selected' => $selectedMenus{$menu} ? 1 : undef,
				};
			}
			$params->{$paramkey} = {'id' => $paramkey, 'values' => \@menuValues};
			$params->{$paramkey.'homemenu'} = $vl->{$homeMenuField} || 0;
			$params->{$paramkey.'homemenuweight'} = $vl->{$weightField} || $defaultWeight;
		}

		$params->{'includedvlids'} = $vl->{'includedvlids'};
		$params->{'excludedvlids'} = $vl->{'excludedvlids'};
		$params->{'pluginWebPageMethodsEditItemSql'} = $vl->{'fulltext'} ? encode_entities($vl->{'fulltext'}, $unsafeChars) : undef;

		return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/webpagemethods_editcustomizeditem.html', $params);
	}
	return handleWebList($client, $params);
}

sub handleWebNewVLTypes {
	my ($client, $params) = @_;

	$params->{'pluginWebPageMethodsTemplates'} = [values %{_getTemplates()}];
	$params->{'pluginWebPageMethodsPostUrl'} = 'plugins/VirtualLibraryCreator/webpagemethods_newitemparameters.html';

	return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/webpagemethods_newitemtypes.html', $params);
}

sub handleWebNewVLParameters {
	my ($client, $params) = @_;

	my $templateId = $params->{'itemtemplate'};
	my $template = _getTemplates()->{$templateId};

	$params->{'pluginWebPageMethodsNewItemTemplate'} = $templateId;

	if (defined($template->{'parameter'})) {
		my @parametersToSelect = map { buildParameterFormField($_) } @{_getUsableParameters($template)};
		_setCustomTagInfo($params);
		$params->{'pluginWebPageMethodsNewItemParameters'} = \@parametersToSelect;
		$params->{'templateName'} = $template->{'name'};
	}
	return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/webpagemethods_newitemparameters.html', $params);
}

sub handleWebSaveNewVL {
	my ($client, $params) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('Start handleWebSaveNewVL');

	my $templateId = $params->{'itemtemplate'};
	main::DEBUGLOG && $log->is_debug && $log->debug('templateId = '.Data::Dump::dump($templateId));
	$params->{'pluginWebPageMethodsError'} = undef;

	checkFilePaths($params);

	my $template = _getTemplates()->{$templateId};
	(my $templateFile = $templateId) =~ s/\.sql\.xml$/.sql.template/;
	(my $fallbackFilename = $templateId) =~ s/\.sql\.xml$//;

	my $fileName = lc($params->{'itemparameter_virtuallibraryname'}) || lc($fallbackFilename);
	$fileName = lc(Slim::Utils::Text::ignoreCase($fileName, 1));
	$fileName =~ s/[\s]+/_/g;
	$fileName = unescape($fileName);
	my $dir = $prefs->get('customvirtuallibrariesfolder');

	# if file name exists, append number
	if (-e catfile($dir, $fileName.'.sql') || -e catfile($dir, $fileName.'.customvalues.xml')) {
		my $i = 1;
		while (-e catfile($dir, $fileName.'_'.$i.'.sql') || -e catfile($dir, $fileName.'_'.$i.'.customvalues.xml')) {
			$i++;
		}
		$fileName .= '_'.$i;
	}
	$params->{'changedvl'} = $fileName;

	my %templateParameters = ();
	for my $p (@{_getUsableParameters($template)}) {
		$templateParameters{$p->{'id'}} = getValueOfTemplateParameter($params, buildParameterFormField($p));
	}
	$templateParameters{'basetemplate'} = $template->{'name'};

	$params->{'fulltext'} = fillTemplate($templateFile, \%templateParameters);

	if (_saveSimpleItem($params, catfile($dir, $fileName.'.customvalues.xml'), $templateId, catfile($dir, $fileName.'.sql'))) {
		$params->{'vlrefresh'} = 2 if $templateParameters{'enabled'} && !$prefs->get('vlstempdisabled');
	} else {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_SAVEFAILED');
	}
	return handleWebList($client, $params);
}


sub handleWebSaveVL {
	my ($client, $params) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('Start handleWebSaveVL (after editing)');

	checkFilePaths($params);

	my $templateId = $params->{'itemtemplate'};
	my $template = _getTemplates()->{$templateId};
	(my $templateFile = $templateId) =~ s/\.sql\.xml$/.sql.template/;

	my %templateParameters = ();
	for my $p (@{_getUsableParameters($template)}) {
		$p = buildParameterFormField($p) if parameterIsSpecified($params, $p);
		$templateParameters{$p->{'id'}} = getValueOfTemplateParameter($params, $p);
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('templateParameters = '.Data::Dump::dump(\%templateParameters));

	$templateParameters{'basetemplate'} = $template->{'name'};
	$templateParameters{'exacttitlesearch'} = $prefs->get('exacttitlesearch');

	$params->{'fulltext'} = fillTemplate($templateFile, \%templateParameters);
	$params->{'pluginWebPageMethodsError'} = undef;
	$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_MISSING_VLNAME') unless $params->{'itemparameter_virtuallibraryname'};

	my $dir = $prefs->get('customvirtuallibrariesfolder');
	$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_MISSING_CUSTOMDIR') unless defined $dir && -d $dir;

	my $file = unescape($params->{'file'});
	if (_saveSimpleItem($params, catfile($dir, $file.'.customvalues.xml'), $templateId, catfile($dir, $file.'.sql'))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('saveSimpleItem succeeded');
		$params->{'changedvl'} = $params->{'file'};
		$params->{'vlrefresh'} = 3 unless (!$templateParameters{'enabled'} && !$params->{'vlwasenabledbefore'}) || $prefs->get('vlstempdisabled');
		return handleWebList($client, $params);
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('saveSimpleItem FAILED - return to edit mode');
	return Slim::Web::HTTP::filltemplatefile('plugins/VirtualLibraryCreator/webpagemethods_edititem.html', $params);
}

sub handleWebSaveCustomizedVL {
	my ($client, $params) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('params from save page = '.Data::Dump::dump($params));

	my %menuOptions = ('browsemenusartists' => 6, 'browsemenusalbums' => 11, 'browsemenusmisc' => 3);
	my (@artistMenus, @albumMenus, @miscMenus);
	for my $key (keys %menuOptions) {
		for my $i (1..$menuOptions{$key}) {
			next unless $params->{$key.'_'.$i};
			push @artistMenus, $i if $key eq 'browsemenusartists';
			push @albumMenus, $i if $key eq 'browsemenusalbums';
			push @miscMenus, $i if $key eq 'browsemenusmisc';
		}
	}

	my $data = "-- VirtualLibraryName: ".($params->{'name'} || $params->{'file'})."\n";
	$data .= "-- VirtualLibraryEnabled: yes\n" if $params->{'enabled'};
	$data .= "-- VirtualLibraryDailyVLrefresh: yes\n" if $params->{'dailyvlrefresh'};
	$data .= "-- VirtualLibraryInitOrder: ".$params->{'libraryinitorder'}."\n" if $params->{'libraryinitorder'};

	if (@artistMenus) { $data .= "-- VirtualLibraryBrowseMenusArtists: ".join(',', @artistMenus)."\n" }
	$data .= "-- VirtualLibraryBrowseMenusArtistsHomeMenu: yes\n" if $params->{'browsemenusartistshomemenu'};
	$data .= "-- VirtualLibraryBrowseMenusArtistsHomeMenuWeight: ".$params->{'browsemenusartistshomemenuweight'}."\n" if $params->{'browsemenusartistshomemenuweight'};

	if (@albumMenus) { $data .= "-- VirtualLibraryBrowseMenusAlbums: ".join(',', @albumMenus)."\n" }
	$data .= "-- VirtualLibraryBrowseMenusAlbumsHomeMenu: yes\n" if $params->{'browsemenusalbumshomemenu'};
	$data .= "-- VirtualLibraryBrowseMenusAlbumsHomeMenuWeight: ".$params->{'browsemenusalbumshomemenuweight'}."\n" if $params->{'browsemenusalbumshomemenuweight'};

	if (@miscMenus) { $data .= "-- VirtualLibraryBrowseMenusMisc: ".join(',', @miscMenus)."\n" }
	$data .= "-- VirtualLibraryBrowseMenusMiscHomeMenu: yes\n" if $params->{'browsemenusmischomemenu'};
	$data .= "-- VirtualLibraryBrowseMenusMiscHomeMenuWeight: ".$params->{'browsemenusmischomemenuweight'}."\n" if $params->{'browsemenusmischomemenuweight'};

	$data .= "-- VirtualLibraryIncludedVLs: ".$params->{'includedvlids'}."\n" if $params->{'includedvlids'};
	$data .= "-- VirtualLibraryExcludedVLs: ".$params->{'excludedvlids'}."\n" if $params->{'excludedvlids'};
	$data .= $params->{'pluginWebPageMethodsEditItemSql'};

	main::DEBUGLOG && $log->is_debug && $log->debug('fulltext file data = '.$data);

	my $dir = $prefs->get('customvirtuallibrariesfolder');
	my $file = unescape($params->{'pluginWebPageMethodsEditItemID'}).'.sql';
	my $url = catfile($dir, $file);

	_writeFile($params, $url, Slim::Utils::Unicode::utf8decode_locale($data));

	if ($params->{'pluginWebPageMethodsError'}) {
		$params->{'pluginWebPageMethodsError'} = string('PLUGIN_VIRTUALLIBRARYCREATOR_ERROR_SAVEFAILED');
	} else {
		$params->{'changedvl'} = $params->{'pluginWebPageMethodsEditItemID'};
		$params->{'vlrefresh'} = 3 unless (!$params->{'enabled'} && !$params->{'vlwasenabledbefore'}) || $prefs->get('vlstempdisabled');
	}
	return handleWebList($client, $params);
}

sub handleWebRemoveVL {
	my ($client, $params) = @_;
	my $itemId = $params->{'item'};
	$items = readItemConfiguration($client)->{'webvirtuallibraries'} unless defined($items);

	my $dir = $prefs->get('customvirtuallibrariesfolder');
	if (defined($dir) && -d $dir) {
		for my $ext ('customvalues.xml', 'sql') {
			my $file = catfile($dir, unescape($itemId).'.'.$ext);
			next unless -e $file;
			unlink($file) or $log->warn("Unable to delete file: $file: $!");
		}
	}

	$params->{'vlrefresh'} = 4 unless $prefs->get('vlstempdisabled') || !$items->{$itemId}{'enabled'};
	return handleWebList($client, $params);
}

sub toggleTempDisabledState {
	my ($client, $params) = @_;
	my $tmpDisabledState = $prefs->get('vlstempdisabled');
	main::DEBUGLOG && $log->is_debug && $log->debug('Current temp. disabled state = '.Data::Dump::dump($tmpDisabledState));
	$prefs->set('vlstempdisabled', $tmpDisabledState ? 0 : 1);
	main::DEBUGLOG && $log->is_debug && $log->debug('New temp. disabled state = '.Data::Dump::dump($prefs->get('vlstempdisabled')));
	$params->{'vlrefresh'} = 5;
	return handleWebList($client, $params);
}

sub manualglobalrefresh {
	my ($client, $params) = @_;
	$params->{'vlrefresh'} = 1;
	$prefs->set('manualrefresh', 1);
	return handleWebList($client, $params);
}



### virtual library folder & list helpers

sub createVirtualLibrariesFolder {
	my $parentFolder = shift || $prefs->get('customdirparentfolderpath') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $virtualLibrariesFolder = catdir($parentFolder, 'VirtualLibraryCreator');
	if (!-d $virtualLibrariesFolder && !mkdir($virtualLibrariesFolder, 0755)) {
		$log->error("Could not create VirtualLibraryCreator folder in parent folder '$parentFolder'! Please make sure that LMS has read/write permissions (755) for the parent folder: $!");
		return;
	}
	$prefs->set('customvirtuallibrariesfolder', $virtualLibrariesFolder);
	return 1;
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
		my $persistentVLID = $values->{'id'};
		next if $curVLID && $persistentVLID eq $curVLID;
		push @items, {
			name => $displayName,
			sortName => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
			value => $persistentVLID,
			id => $persistentVLID,
		};
	}
	push @items, {name => 'No virtual libraries found', value => '', id => ''} unless @items;
	@items = sort {lc($a->{'sortName'}) cmp lc($b->{'sortName'})} @items if scalar @items > 1;
	return \@items;
}

sub getVLBrowseMenus {
	my $type = shift;
	return [] if $prefs->get('allbrowsemenus_tmpdisabled') || !$type;
	my $requestedMenus = $browseMenus{$type};
	my @result = map {
		{'id' => $_, 'name' => $requestedMenus->{$_}{'name'}, 'value' => $_}
	} sort { ($requestedMenus->{$a}{'sortval'} || 0) <=> ($requestedMenus->{$b}{'sortval'} || 0) } keys %{$requestedMenus};
	main::DEBUGLOG && $log->is_debug && $log->debug('getVLBrowseMenus result = '.Data::Dump::dump(\@result));
	return \@result;
}

sub getVLBrowseMenusArtists { return getVLBrowseMenus('artists') }
sub getVLBrowseMenusAlbums { return getVLBrowseMenus('albums') }
sub getVLBrowseMenusMisc { return getVLBrowseMenus('misc') }

sub isTimeOrEmpty {
	my (undef, $arg) = @_;
	return 1 if !$arg || $arg eq '';
	return 1 if $arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg;
	return 0;
}

sub registerCustomString {
	my $string = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('string = '.Data::Dump::dump($string));
	if (!Slim::Utils::Strings::stringExists($string)) {
		my $token = 'PLUGIN_VLC_BROWSEMENUS_'.uc(Slim::Utils::Text::ignoreCase($string, 1));
		$token =~ s/\s/_/g;
		Slim::Utils::Strings::storeExtraStrings([{strings => {EN => $string}, token => $token}]) if !Slim::Utils::Strings::stringExists($token);
		return $token;
	}
	return $string;
}

### file reading helpers
# readTemplateConfiguration, _getTemplates, readItemConfiguration, _readConfigFiles, _parseTemplate, _parseContent, _parseTemplateContent, _parseLineParam,
# _externalCheck and trim_all live in Common.pm (imported via ':all') so Importer.pm in the external scanner process, which never loads this module, can use them too

sub _readDataFile {
	my $fileName = shift;
	my $dir = $prefs->get('customvirtuallibrariesfolder');
	return unless defined($dir) && -d $dir;
	my $path = catfile($dir, $fileName);
	main::DEBUGLOG && $log->is_debug && $log->debug("Loading item data from: $path");
	return unless -f $path;
	my $content = eval { read_file($path) };
	$log->error("Failed to load item data because: $@") if $@;
	return defined($content) ? _decodeContent($content, $fileName) : undef;
}

sub _loadTemplateValues {
	my $itemId = shift;
	my $content = _readDataFile($itemId.'.customvalues.xml');
	return unless defined($content);
	my $xml = eval { XMLin($content, forcearray => ['parameter', 'value'], keyattr => []) };
	if ($@) {
		$log->error("Failed to parse configuration because: $@");
		return;
	}
	return $xml->{'template'};
}

### editing, saving and deleting virtual libraries

my %parameterListCache;    # page-scoped memoization for getSQLTemplateData/getFunctionTemplateData, reset below

sub _getUsableParameters {
	my $template = shift;
	%parameterListCache = ();
	my $parameters = $template->{'parameter'};
	return [] unless defined($parameters);
	$parameters = [$parameters] if ref($parameters) ne 'ARRAY';

	my @usable = ();
	for my $p (@{$parameters}) {
		next unless defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'});
		next if defined($p->{'requireplugins'}) && !Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
		if (defined($p->{'minlmsversion'}) && Slim::Utils::Versions->compareVersions($::VERSION, $p->{'minlmsversion'}) == -1) {
			main::DEBUGLOG && $log->is_debug && $log->debug('LMS version = '.$::VERSION.' -- min. LMS version for param "'.$p->{'id'}.'" = '.$p->{'minlmsversion'});
			next;
		}
		push @usable, $p;
	}
	return \@usable;
}

sub buildParameterFormField {
	my ($p, $currentValues) = @_;
	my %field = %{$p};

	if ($field{'type'} eq 'text' || $field{'type'} eq 'number' || $field{'type'} eq 'searchtext' || $field{'type'} eq 'searchurl') {
		$field{'elementsize'} = $largeFields{$field{'id'}} if $largeFields{$field{'id'}};
		$field{'elementsize'} = $mediumFields{$field{'id'}} if $mediumFields{$field{'id'}};
		$field{'elementsize'} = $smallFields{$field{'id'}} if $smallFields{$field{'id'}};
	}
	$field{'elementsize'} = 50 if $field{'type'} eq 'multivaltext';

	if ($field{'type'} =~ /^sql/) {
		my $listValues = getSQLTemplateData($field{'data'});
		unshift @{$listValues}, _emptyListValue() if $field{'type'} =~ /optional/;
		$field{'values'} = $listValues;
	} elsif ($field{'type'} =~ /function/) {
		my $listValues = getFunctionTemplateData($field{'data'});
		unshift @{$listValues}, _emptyListValue() if $field{'type'} =~ /optional.*list$/;
		if ($field{'value'}) { $_->{'selected'} = 1 for @{$listValues} }
		$field{'values'} = $listValues;
	} elsif ($field{'type'} =~ /virtuallibraries/) {
		my $listValues = getVirtualLibraries();
		unshift @{$listValues}, _emptyListValue();
		if ($field{'value'}) { $_->{'selected'} = 1 for @{$listValues} }
		$field{'values'} = $listValues;
	} elsif ($field{'type'} =~ /list$/ || $field{'type'} =~ /checkboxes$/) {
		my @listValues = ();
		for my $value (split(/,/, $field{'data'})) {
			my @idName = split(/=/, $value);
			push @listValues, {
				'id' => $idName[0], 'name' => $idName[1],
				'value' => scalar(@idName) > 2 ? $idName[2] : $idName[0],
			};
		}
		unshift @listValues, _emptyListValue() if $field{'type'} =~ /optional.*list$/;
		$field{'values'} = \@listValues;
	}

	if (defined($currentValues)) {
		if ($field{'type'} =~ /^sql/ || $field{'type'} =~ /function/ || $field{'type'} =~ /list$/ || $field{'type'} =~ /checkboxes$/) {
			for my $v (@{$field{'values'}}) {
				if (($field{'id'} eq 'includedratings' || $field{'id'} eq 'exactrating') && defined($currentValues->{$v->{'value'}})) {
					$v->{'selected'} = 1;
				} elsif ($currentValues->{$v->{'value'}}) {
					$v->{'selected'} = 1;
				} else {
					$v->{'selected'} = undef;
				}
			}
		} else {
			$field{'value'} = $_ for keys %{$currentValues};
		}
	}
	return \%field;
}

sub _setCustomTagInfo {
	my $params = shift;
	$params->{'CTIenabled'} = Slim::Utils::PluginManager->isEnabled('Plugins::CustomTagImporter::Plugin');
	if ($params->{'CTIenabled'}) {
		my $sth = Slim::Schema->dbh->prepare("select count(distinct attr) from customtagimporter_track_attributes where customtagimporter_track_attributes.type='customtag'");
		$sth->execute();
		($params->{'customtagcount'}) = $sth->fetchrow_array;
		$sth->finish();
	}
}

sub _saveSimpleItem {
	my ($params, $url, $templateId, $customUrl) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('Start _saveSimpleItem');

	my $template = _getTemplates()->{$templateId};

	if (!$params->{'pluginWebPageMethodsError'}) {
		my $data = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<virtuallibrarycreator>\n\t<template>\n\t\t<id>".encode_entities($templateId, $unsafeChars).'</id>';
		$data .= "\n\t\t<templateversion>".$template->{'templateversion'}.'</templateversion>' if $template->{'templateversion'};

		for my $p (@{_getUsableParameters($template)}) {
			$p = buildParameterFormField($p) if parameterIsSpecified($params, $p);
			my $attrs = '';
			$attrs .= ' quotevalue="1"' if $p->{'quotevalue'};
			$attrs .= ' rawvalue="1"' if $p->{'rawvalue'};
			$data .= "\n\t\t<parameter type=\"text\" id=\"".$p->{'id'}."\"$attrs>".getXMLValueOfTemplateParameter($params, $p).'</parameter>';
		}
		$data .= "\n\t</template>\n</virtuallibrarycreator>\n";

		_writeFile($params, $url, $data);

		if (!$params->{'pluginWebPageMethodsError'}) {
			my $sqlData = Slim::Utils::Unicode::utf8decode_locale($params->{'fulltext'});
			$sqlData =~ s/\r+\n/\n/g;
			_writeFile($params, $customUrl, $sqlData);
		}
	}

	if ($params->{'pluginWebPageMethodsError'}) {
		my @parametersToSelect = ();
		for my $p (@{_getUsableParameters($template)}) {
			my $field = buildParameterFormField($p);
			my $value = getXMLValueOfTemplateParameter($params, $field);
			if (defined($value) && $value ne '') {
				my $xmlValue = eval { XMLin('<data>'.$value.'</data>', forcearray => ['value'], keyattr => []) };
				if (defined($xmlValue)) {
					my %valuesHash = map {$_ => $_} grep {ref($_) ne 'HASH'} @{$xmlValue->{'value'}};
					$valuesHash{''} = '' unless %valuesHash;
					$field = buildParameterFormField($p, \%valuesHash);
				}
			}
			push @parametersToSelect, $field;
		}
		$params->{'pluginWebPageMethodsEditItemParameters'} = \@parametersToSelect;
		$params->{'pluginWebPageMethodsEditItemTemplate'} = $templateId;
		$params->{'pluginWebPageMethodsEditItemFileUnescaped'} = unescape($params->{'file'});
		return;
	}
	return 1;
}

sub _writeFile {
	my ($params, $path, $data) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("Opening configuration file: $path");
	open(my $fh, '>:encoding(UTF-8)', $path) or do {
		$params->{'pluginWebPageMethodsError'} = "Error saving $path: ".$!;
		$log->error("Error saving $path: ".$!);
		return;
	};
	main::DEBUGLOG && $log->is_debug && $log->debug("Writing to file: $path");
	print $fh $data;
	main::DEBUGLOG && $log->is_debug && $log->debug('Writing to file succeeded');
	close $fh;
}

sub checkFilePaths {
	my $params = shift;
	my $prefix = 'file:///';
	for my $i (1..3) {
		my $key = 'itemparameter_filepath'.$i;
		last unless $params->{$key};
		next if Slim::Music::Info::isURL($params->{$key});
		next unless ($params->{$key.'_searchtype'} || '') =~ /STARTS/ && index($params->{$key}, $prefix) != 0;
		main::DEBUGLOG && $log->is_debug && $log->debug('incorrect or missing file path '.$i.' prefix');
		$params->{$key} = setFilePathPrefix($params->{$key}, $prefix);
	}
}

sub setFilePathPrefix {
	my ($path, $prefix) = @_;
	if (index($path, $prefix) != 0) {
		main::DEBUGLOG && $log->is_debug && $log->debug('NO correct prefix');
		$path = $prefix.$path;
	}
	my $dirSep = File::Spec->canonpath('/');
	$path =~ s<(?:\Q$dirSep\E){4,}><$dirSep$dirSep$dirSep>;
	return $path;
}



### template parameter handling

sub quoteValue {
	my $value = shift;
	$value =~ s/\'/\'\'/g;
	return $value;
}

sub _emptyListValue {
	return {'id' => '', 'name' => '', 'value' => ''};
}

sub _getSelectedValues {
	my ($params, $parameter) = @_;
	my $paramName = 'itemparameter_'.$parameter->{'id'};
	if ($parameter->{'type'} =~ /multiplelist$/) {
		return getMultipleListQueryParameter($params, $paramName);
	}
	return getCheckBoxesQueryParameter($params, $paramName);
}

sub parameterIsSpecified {
	my ($params, $parameter) = @_;
	if ($parameter->{'type'} =~ /multiplelist$/ || $parameter->{'type'} =~ /checkboxes$/) {
		return scalar(keys %{_getSelectedValues($params, $parameter)}) > 0 ? 1 : 0;
	} elsif ($parameter->{'type'} =~ /singlelist$/) {
		return defined($params->{'itemparameter_'.$parameter->{'id'}}) ? 1 : 0;
	}
	return $params->{'itemparameter_'.$parameter->{'id'}} ? 1 : 0;
}

sub getValueOfTemplateParameter {
	my ($params, $parameter) = @_;
	my $result = '';

	if ($parameter->{'type'} =~ /multiplelist$/ || $parameter->{'type'} =~ /checkboxes$/) {
		my $selectedValues = _getSelectedValues($params, $parameter);
		main::DEBUGLOG && $log->is_debug && $log->debug('Got '.scalar(keys %{$selectedValues}).' values for '.$parameter->{'id'});
		for my $item (@{$parameter->{'values'}}) {
			if (defined($selectedValues->{$item->{'id'}})) {
				$result .= ',' if $result ne '';
				my $thisvalue = $item->{'value'};
				if ($parameter->{'id'} eq 'includeddecades' && $thisvalue != 0) {
					$thisvalue = join(',', $thisvalue, map {$thisvalue + $_} 1..9);
				}
				$thisvalue = quoteValue($thisvalue) unless $parameter->{'rawvalue'};
				$result .= $parameter->{'quotevalue'} ? "'".encode_entities($thisvalue, $unsafeChars)."'" : encode_entities($thisvalue, $unsafeChars);
				main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}." = $thisvalue");
			}
		}
	} elsif ($parameter->{'type'} =~ /singlelist$/) {
		my $selectedValue = Slim::Utils::Unicode::utf8decode_locale($params->{'itemparameter_'.$parameter->{'id'}});
		for my $item (@{$parameter->{'values'}}) {
			if ($selectedValue && $selectedValue eq $item->{'id'}) {
				my $thisvalue = $item->{'value'};
				$thisvalue = quoteValue($thisvalue) unless $parameter->{'rawvalue'};
				$result = $parameter->{'quotevalue'} ? "'".encode_entities($thisvalue, $unsafeChars)."'" : encode_entities($thisvalue, $unsafeChars);
				main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}." = $thisvalue");
				last;
			}
		}
	} elsif ($parameter->{'type'} eq 'multivaltext') {
		if ($params->{'itemparameter_'.$parameter->{'id'}}) {
			my $thisvalue = Slim::Utils::Unicode::utf8decode_locale($params->{'itemparameter_'.$parameter->{'id'}});
			main::INFOLOG && $log->is_info && $log->info('thisvalue = '.Data::Dump::dump($thisvalue));
			# customtagvalues 'contains' is a LIKE substring match: it needs LIKE escaping instead of the value quoting used for oneof/equals below
			(my $searchTypeId = $parameter->{'id'}) =~ s/values/searchtype/;
			if ($parameter->{'id'} =~ /customtagvalues/ && ($params->{'itemparameter_'.$searchTypeId} || '') eq 'contains') {
				$thisvalue = quoteValue($thisvalue) unless $parameter->{'rawvalue'};
				$result = encode_entities(handleSearchText($thisvalue, 1), $unsafeChars);
			} else {
				my $quotedTextVal;
				for my $thisParamVal (split(/;/, $thisvalue)) {
					$thisParamVal = quoteValue($thisParamVal) unless $parameter->{'rawvalue'};
					$quotedTextVal .= ($quotedTextVal ? ',' : '').($parameter->{'quotevalue'} ? "'".encode_entities(trimLeadTail($thisParamVal), $unsafeChars)."'" : encode_entities(trimLeadTail($thisParamVal), $unsafeChars));
				}
				main::INFOLOG && $log->is_info && $log->info('Got '.$parameter->{'id'}.' = '.Data::Dump::dump($quotedTextVal));
				$result = $quotedTextVal;
			}
		}
	} else {
		if ($params->{'itemparameter_'.$parameter->{'id'}}) {
			my $thisvalue = Slim::Utils::Unicode::utf8decode_locale($params->{'itemparameter_'.$parameter->{'id'}});
			$thisvalue = quoteValue($thisvalue) if !$parameter->{'rawvalue'} && $parameter->{'id'} ne 'virtuallibraryname' && $parameter->{'type'} ne 'searchurl';
			$thisvalue = handleSearchText($thisvalue, $parameter->{'id'} =~ /commentssearchstring/ ? 1 : 0) if $parameter->{'type'} eq 'searchtext';
			$thisvalue = handleSearchURL($thisvalue) if $parameter->{'type'} eq 'searchurl';
			if ($parameter->{'type'} eq 'text' && $parameter->{'id'} =~ /filetimestamp$/) {
				my ($days, $months, $years) = split(m|/|, $thisvalue);
				$thisvalue = timelocal(0, 0, 0, $days, $months - 1, $years);
			}
			return $parameter->{'quotevalue'} ? "'".encode_entities($thisvalue, $unsafeChars)."'" : encode_entities($thisvalue, $unsafeChars);
		} elsif ($parameter->{'type'} =~ /checkbox$/) {
			$result = '0';
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}." = $result");
	}
	return $result;
}

sub getXMLValueOfTemplateParameter {
	my ($params, $parameter) = @_;
	my $result = '';

	if ($parameter->{'type'} =~ /multiplelist$/ || $parameter->{'type'} =~ /checkboxes$/) {
		my $selectedValues = _getSelectedValues($params, $parameter);
		main::DEBUGLOG && $log->is_debug && $log->debug('Got '.scalar(keys %{$selectedValues}).' values for '.$parameter->{'id'}.' to convert to XML');
		for my $item (@{$parameter->{'values'}}) {
			if (defined($selectedValues->{$item->{'id'}})) {
				$result .= '<value>'.encode_entities($item->{'value'}, $unsafeChars).'</value>';
				main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}.' = '.$item->{'value'});
			}
		}
	} elsif ($parameter->{'type'} =~ /singlelist$/) {
		my $selectedValue = Slim::Utils::Unicode::utf8decode_locale($params->{'itemparameter_'.$parameter->{'id'}});
		for my $item (@{$parameter->{'values'}}) {
			if ($selectedValue && $selectedValue eq $item->{'id'}) {
				$result .= '<value>'.encode_entities($item->{'value'}, $unsafeChars).'</value>';
				main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}.' = '.$item->{'value'});
				last;
			}
		}
	} else {
		if (defined($params->{'itemparameter_'.$parameter->{'id'}}) && $params->{'itemparameter_'.$parameter->{'id'}} ne '') {
			my $value = Slim::Utils::Unicode::utf8decode_locale($params->{'itemparameter_'.$parameter->{'id'}});
			# persisted to .customvalues.xml and redisplayed in the edit form: keep it raw and unescaped,
			# otherwise handleSearchText's escaping would be applied again on every save
			$value = handleSearchURL($value) if $parameter->{'type'} eq 'searchurl';
			$result = '<value>'.encode_entities($value, "%_&<>'\"").'</value>';
			main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}." = $value");
		} else {
			$result = '<value>0</value>' if $parameter->{'type'} =~ /checkbox$/;
			main::DEBUGLOG && $log->is_debug && $log->debug('Got '.$parameter->{'id'}." = $result");
		}
	}
	return $result;
}

sub getMultipleListQueryParameter {
	my ($params, $parameter) = @_;
	my %result = ();
	for my $param (split /\&/, $params->{url_query} || '') {
		if ($param =~ /^([^=]+)=(.*)$/) {
			my $name = unescape($1);
			my $value = unescape($2);
			if ($name eq $parameter && $value ne '*' && $value ne '') {
				$value = Slim::Utils::Unicode::utf8on($value);
				$value = Slim::Utils::Unicode::utf8encode_locale($value);
				$result{$value} = 1;
			} elsif ($name eq $parameter) {
				$result{$value} = 1;
			}
		}
	}
	return \%result;
}

sub getCheckBoxesQueryParameter {
	my ($params, $parameter) = @_;
	my %result = ();
	for my $key (keys %{$params}) {
		if ($key =~ /^\Q$parameter\E_(.*)/) {
			my $id = unescape($1);
			if ($id ne '*' && $id ne '') {
				$id = Slim::Utils::Unicode::utf8on($id);
				$id = Slim::Utils::Unicode::utf8encode_locale($id);
			}
			$result{$id} = 1;
		}
	}
	return \%result;
}

sub getSQLTemplateData {
	my $sqlstatements = shift;
	return [ map { { %$_ } } @{$parameterListCache{$sqlstatements}} ] if $parameterListCache{$sqlstatements};

	my @result = ();
	my $dbh = Slim::Schema->dbh;

	for my $sql (split(/[;]/, $sqlstatements)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('sql = '.Data::Dump::dump($sql));
		$sql =~ s/^\s+//g;
		$sql =~ s/\s+$//g;
		next unless $sql;
		eval {
			my $sth = $dbh->prepare($sql);
			main::DEBUGLOG && $log->is_debug && $log->debug('Executing: '.Data::Dump::dump($sql));
			$sth->execute() or do {
				$log->error('Error executing: '.Data::Dump::dump($sql));
				$sql = undef;
			};
			if ($sql && $sql =~ /^SELECT/i) {
				main::DEBUGLOG && $log->is_debug && $log->debug('Executing and collecting: '.Data::Dump::dump($sql));
				my ($id, $name, $value);
				$sth->bind_col(1, \$id);
				$sth->bind_col(2, \$name);
				$sth->bind_col(3, \$value);
				while ($sth->fetch()) {
					next unless defined($id);
					push @result, {
						'id' => Slim::Utils::Unicode::utf8decode($id, 'utf8'),
						'name' => Slim::Utils::Unicode::utf8decode($name // '', 'utf8'),
						'value' => Slim::Utils::Unicode::utf8decode($value // '', 'utf8'),
					};
				}
			}
			$sth->finish();
		};
		$log->warn('Database error running '.(defined($sql) ? $sql : 'sql statement').": $@") if $@;
	}
	$parameterListCache{$sqlstatements} = \@result;
	return [ map { { %$_ } } @result ];
}

sub getFunctionTemplateData {
	my $data = shift;
	return [ map { { %$_ } } @{$parameterListCache{$data}} ] if $parameterListCache{$data};

	my @params = split(/\,/, $data);
	my @result = ();
	if (scalar(@params) == 2) {
		my ($object, $function) = @params;
		if (UNIVERSAL::can($object, $function)) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Getting values for: $function");
			no strict 'refs';
			my $items = eval { &{$object.'::'.$function}() };
			$log->warn("Function call error: $@") if $@;
			use strict 'refs';
			@result = @{$items} if defined($items);
		}
	} else {
		$log->warn("Error getting values for: $data, incorrect number of parameters ".scalar(@params));
	}
	$parameterListCache{$data} = \@result;
	return [ map { { %$_ } } @result ];
}

sub handleSearchURL {
	my $url = shift;
	$url =~ s/^\s*//;
	$url =~ s/\s+$//;
	return $url;
}

sub handleSearchText {
	my ($searchString, $skipExact) = @_;
	$searchString =~ s/^\s*//;
	$searchString =~ s/\s+$//;
	# '%' is doubled: the saved .sql goes through sprintf() (library id), a lone '%' would be read as a format directive
	$searchString =~ s/([\\%_])/$1 eq '%' ? "\\%%" : "\\$1"/ge;
	$searchString = Slim::Utils::Unicode::utf8decode_locale($searchString);
	if (!$prefs->get('exacttitlesearch') && !$skipExact) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Not using exact title search');
		$searchString = Slim::Utils::Text::ignoreCase($searchString, 1);
	}
	return $searchString;
}

sub trimLeadTail {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}



### Template Toolkit

sub _getTemplateHandler {
	return $templateHandler if defined($templateHandler);

	my @includePath = ();
	for my $pluginDir (Slim::Utils::OSDetect::dirsFor('Plugins')) {
		my $templateDir = catdir($pluginDir, 'VirtualLibraryCreator', 'Templates');
		next unless -d $templateDir;
		push @includePath, $templateDir;
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('templateDirectories = '.Data::Dump::dump(\@includePath));

	$templateHandler = Template->new({
		INCLUDE_PATH => \@includePath,
		COMPILE_DIR => catdir($serverPrefs->get('cachedir'), 'templates'),
		FILTERS => {
			'string' => \&Slim::Utils::Strings::string,
			'getstring' => \&Slim::Utils::Strings::getString,
			'resolvestring' => \&Slim::Utils::Strings::resolveString,
			'uri' => \&URI::Escape::uri_escape_utf8,
			'unuri' => \&URI::Escape::uri_unescape,
			'utf8decode' => \&Slim::Utils::Unicode::utf8decode,
			'utf8encode' => \&Slim::Utils::Unicode::utf8encode,
			'utf8on' => \&Slim::Utils::Unicode::utf8on,
			'utf8off' => \&Slim::Utils::Unicode::utf8off,
			'fileurluri' => \&_fileURLFromPathUri,
		},
		EVAL_PERL => 1,
	});
	return $templateHandler;
}

sub fillTemplate {
	my ($filename, $params) = @_;
	my $output = '';
	$params->{'LOCALE'} = 'utf-8';
	my $tmpl = _getTemplateHandler();
	$log->error('ERROR parsing template: '.$tmpl->error()) unless $tmpl->process($filename, $params, \$output);
	return $output;
}

sub _fileURLFromPathUri {
	# value arrives entity-encoded and _parseContent decodes the whole .sql again: decode first, encode last
	my $path = decode_entities(shift);
	# re-encode to raw UTF-8 bytes so ord() below sees single bytes, like tracks.url ("All paths should be in raw bytes", LMS Misc.pm)
	utf8::encode($path);

	# own byte-wise percent-encoding: URI::Escape's custom-pattern mode is eval-based and misreads '@A-Za-z' as an array on older bundled versions;
	# safe set verified against real tracks.url values (apostrophe -> %27, [ ] unescaped);
	# '%' is doubled because the saved .sql goes through sprintf() (library id), which is also why template wildcards are '%%'
	my $uri = $path;
	$uri =~ s/([^A-Za-z0-9!\$&()*+,\-.:=\@_~\/\[\]])/sprintf('%%%%%02X', ord($1))/ge;

	# LIKE escaping for ESCAPE '\'; '%%' (one post-sprintf '%') is handled as one unit
	$uri =~ s/(%%|_)/\\$1/g;

	return encode_entities($uri, $unsafeChars);
}



### release types (localized display names)

sub getReleaseTypeList {
	my $list = getSQLTemplateData("select distinct albums.release_type,albums.release_type,albums.release_type from albums order by albums.release_type asc");
	$_->{'name'} = _releaseTypeName($_->{'name'}) for @{$list};
	return $list;
}

sub _releaseTypeName {
	my $releaseType = shift;
	my $nameToken = uc($releaseType);
	$nameToken =~ s/[^a-z_0-9]/_/ig;
	my $name;
	for ('RELEASE_TYPE_'.$nameToken, 'RELEASE_TYPE_CUSTOM_'.$nameToken, $nameToken) {
		$name = string($_) if Slim::Utils::Strings::stringExists($_);
		last if $name;
	}
	return $name || $releaseType;
}

1;
