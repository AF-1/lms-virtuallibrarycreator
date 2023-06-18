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
use Data::Dumper;
use FindBin qw($Bin);
use Time::HiRes qw(time);

use Plugins::VirtualLibraryCreator::Settings;
use Plugins::VirtualLibraryCreator::ConfigManager::Main;

my $virtualLibraries = undef;
my $webVirtualLibraries = undef;
my $sqlerrors = '';
my $configManager = undef;
my $pluginVersion = undef;
my $isPostScanCall = 0;
my %browseMenus = ();
my $MAIprefs = undef;

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

	if (!$::noweb) {
		Plugins::VirtualLibraryCreator::Settings->new($class);
	}

	Slim::Control::Request::subscribe(sub{
		$isPostScanCall = 1;
		setRefreshCBTimer();
	},[['rescan'],['done']]);
}

sub initPrefs {
	$prefs->init({
		customdirparentfolderpath => $serverPrefs->get('playlistdir'),
		browsemenus_parentfoldername => 'My VLC Menus',
		browsemenus_parentfoldericon => 1,
		dailyvlrefreshtime => '02:30',
		displayhasbrowsemenus => 1,
		displayisdailyrefreshed => 1,
		scheduledinitdelay => 3
	});

	createVirtualLibrariesFolder();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $virtualLibrariesFolder = catdir($_[1], 'VirtualLibraryCreator');
		eval {
			mkdir($virtualLibrariesFolder, 0755) unless (-d $virtualLibrariesFolder);
			chdir($virtualLibrariesFolder);
		} or do {
			$log->error("Could not create or access VLC folder in parent folder '$_[1]'!");
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
			$log->debug('VLC parent folder name for browse menus or its icon changed. Reinitializing collected VL menus.');
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
									2 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSBYGENRE'), 'sortval' => 2},
									3 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM'), 'sortval' => 3},
									4 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS'), 'sortval' => 4},
									5 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY'), 'sortval' => 5},
									6 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS'), 'sortval' => 6},
									7 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE'), 'sortval' => 7},
									8 => {'name' => string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR'), 'sortval' => 8},
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
		$log->debug('current plugin version = '.$pluginVersion.' -- cached plugin version = '.Dumper($cachePluginVersion));

		unless ($cachePluginVersion && $cachePluginVersion eq $pluginVersion && $cache->get('vlc_contributorlist_all') && $cache->get('vlc_contributorlist_albumartists') && $cache->get('vlc_contributorlist_composers') && $cache->get('vlc_genrelist') && $cache->get('vlc_contenttypes')) {
			$log->debug('Refreshing caches for contributors, genres and content types');
			refreshSQLCache();
		}

		# check custom folder
		my $customVLFolder_parentfolderpath = $prefs->get('customdirparentfolderpath') || $serverPrefs->get('playlistdir');
		my $customDir = $prefs->get('customvirtuallibrariesfolder');
		eval {
			chdir($customDir);
		} or do {
			$log->error("Not initializing virtual libraries. Could not access 'VirtualLibraryCreator' folder for custom virtual libraries in parent folder '$customVLFolder_parentfolderpath'! Please make sure that LMS has read/write permissions (755) for the (parent) folder.");
			return;
		};

		# MAI
		if (Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin')) {
			$MAIprefs = preferences('plugin.musicartistinfo');
		}

		initVirtualLibrariesDelayed();
	}
}

sub initVirtualLibraries {
	my $recreateChangedVL = shift;
	$log->debug('Start initializing VLs.');
	my $started = time();

	## update list of available virtual library VLC definitions
	getVLCvirtualLibraryList();

	# if VL includes/excludes other VLC libraries, set library init order accordingly so VLs exist when needed
	if (keys %{$virtualLibraries} > 0) {
		foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
			if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'} || $virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'}) {

				# get VLIDs of VLC(!) base libraries
				my %baseLibrariesVLIDs = ();
				if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'}) {
					foreach (split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'})) {
						$baseLibrariesVLIDs{$_} = 1 if starts_with($_, 'PLUGIN_VLC_VLID_') == 0;
					}
				}
				if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'}) {
					foreach (split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'})) {
						$baseLibrariesVLIDs{$_} = 1 if starts_with($_, 'PLUGIN_VLC_VLID_') == 0;
					}
				}
				$log->debug('baseLibrariesVLIDs = '.Dumper(\%baseLibrariesVLIDs));


				my $thisLibraryInitOrder = 600;
				foreach my $thisLibrary (keys %{$virtualLibraries}) {
					if ($baseLibrariesVLIDs{$virtualLibraries->{$thisLibrary}->{'VLID'}}) {
						my $baseVLinitOrder = $virtualLibraries->{$thisLibrary}->{'libraryinitorder'} || 50;
						if ($thisLibraryInitOrder <= $baseVLinitOrder) {
							$thisLibraryInitOrder = $baseVLinitOrder + 10;
						}
					}
				}
				$virtualLibraries->{$thisVLCvirtualLibrary}->{'libraryinitorder'} = $thisLibraryInitOrder;

			} else {
				$virtualLibraries->{$thisVLCvirtualLibrary}->{'libraryinitorder'} = 50;
			}
		}
	}
	$log->debug('virtual libraries = '.Dumper($virtualLibraries));

	# deregister all VLC menus
	$log->debug('Deregistering VLC menus.');
	deregAllMenus();

	my $LMS_virtuallibraries = Slim::Music::VirtualLibraries->getLibraries();
	$log->debug('Found these registered LMS virtual libraries: '.Dumper($LMS_virtuallibraries));

	## unregister virtual libraries if globally disabled or post-scan call
	if ($prefs->get('vlstempdisabled') || $isPostScanCall) {
		my $VLunregCount = 0;
		foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
			my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
			$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'PLUGIN_VLC_VLID_') == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
				$VLunregCount++;
			}
		}

		if ($prefs->get('vlstempdisabled')) {
			$log->info('VLC VLs globally disabled/paused.'.($VLunregCount ? ' Unregistering all VLC VLs.' : '')) if $prefs->get('vlstempdisabled');
			Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
			return;
		}
		$log->info('Post-scan init.'.($VLunregCount ? ' Unregistering all VLC VLs.' : ''));
	}

	$log->debug('Number of VLC virtual libraries = '.Dumper(scalar keys %{$virtualLibraries}));

	### create/register VLs
	if (keys %{$virtualLibraries} > 0) {

		if (!$isPostScanCall) { # VLs have already been unregistered if post-scan call
			# unregister VLC virtual libraries that are disabled or no longer exist
			foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
				my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
				$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
				if (starts_with($thisVLID, 'PLUGIN_VLC_VLID_') == 0) {
					my $isVLClibrary = 0;
					foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
						next if (!defined ($virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'}));
						my $VLID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'VLID'};
						if ($VLID eq $thisVLID) {
								$log->debug("VL '$VLID' is already registered and still part of VLC VLs.");
								$isVLClibrary = 1;
						}
					}
					if ($isVLClibrary == 0) {
						$log->info("VL '$thisVLID' is disabled or was deleted from VLC. Unregistering VL.");
						Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
					}
				}
			}
		}

		# create/register enabled VLs not yet registered
		my %recentlyCreatedVLIDs = ();

		foreach my $thisVLCvirtualLibrary (sort { ($virtualLibraries->{$a}->{'libraryinitorder'} || 0) <=> ($virtualLibraries->{$b}->{'libraryinitorder'} || 0)} keys %{$virtualLibraries}) {
			my $enabled = $virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
			next if !defined($enabled);

			my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
			$log->debug('item ID = '.$VLCitemID);
			my $VLID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'VLID'};
			$log->debug('VLID = '.$VLID);
			my $libraryInitOrder = $virtualLibraries->{$thisVLCvirtualLibrary}->{'libraryinitorder'};
			$log->debug('libraryInitOrder = '.Dumper($libraryInitOrder));

			my $browsemenu_name = $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'};
			$log->debug('browsemenu_name = '.$browsemenu_name);

			my $sql = replaceParametersInSQL($thisVLCvirtualLibrary); # replace parameters if necessary
			$log->debug('sql = '.$sql);
			my $sqlstatement = qq{$sql};

			my $library = {
				id => $VLID,
				name => $browsemenu_name,
				sql => $sqlstatement,
			};

			# if we have a recently edited VL, unregister it so it can be recreated
			if ($recreateChangedVL && $recreateChangedVL eq $VLCitemID) {
				$log->info("Request to (re)create VL '$VLID'");
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
			}

			my $VLalreadyexists = Slim::Music::VirtualLibraries->getRealId($VLID);
			$log->debug('Check if VL already exists. Returned real library id = '.Dumper($VLalreadyexists));
			if (defined $VLalreadyexists) {
				$log->debug("VL '$VLID' already exists.");
				next;
			}

			$log->debug("VL '$VLID' has not been created yet. Creating & registering it now.");
			eval {
				Slim::Music::VirtualLibraries->registerLibrary($library);
				Slim::Music::VirtualLibraries->rebuild($library->{id});
			};
			if ($@) {
				$log->error("Error registering library '".$library->{'name'}."'. Is SQLite statement valid? Error message: $@");
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
				next;
			} else {
				$recentlyCreatedVLIDs{$VLID} = 1;
			}

			my $trackCount = Slim::Music::VirtualLibraries->getTrackCount($VLID) || 0;
			$log->debug("track count vlib '$browsemenu_name' = ".Slim::Utils::Misc::delimitThousands($trackCount));
			if ($trackCount == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
				$log->info("Unregistering vlib '$browsemenu_name' because it has 0 tracks.");
			}
		}

		$log->debug('Finished creating virtual libraries after '.(time() - $started).' secs.');

		# check if there are VLs that request a daily refresh
		dailyVLrefreshScheduler(\%recentlyCreatedVLIDs);

		initHomeVLMenus();
	}
	$isPostScanCall = 0;

	$log->info('Finished initializing virtual libraries & menus. Total time = '.(time() - $started).' secs.');
}

sub replaceParametersInSQL {
	my $thisVLCvirtualLibrary = shift;
	my %replaceParams = ();
	my $sql = my $sqlCmp = $virtualLibraries->{$thisVLCvirtualLibrary}->{'sql'};

	# included virtual libraries
	if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'}) {
		$log->debug('includedvlids = '.Dumper($virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'}));
		my @includedVLIBrealIDs = ();
		foreach (split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'})) {
			my $VLrealID = Slim::Music::VirtualLibraries->getRealId($_);
			if ($VLrealID) {
				$log->debug("Will replace permanent virtual library ID '$_' with current real ID '$VLrealID'.");
				push @includedVLIBrealIDs, Slim::Schema->storage->dbh()->quote(Slim::Music::VirtualLibraries->getRealId($_));
			} else {
				$log->error("The virtual library '$_' of your parameter 'included virtual libraries' in your virtual library '".$virtualLibraries->{$thisVLCvirtualLibrary}->{'name'}."' does not exist. Your virtual library definition will not work (correctly).");
			}
		}
		if (scalar @includedVLIBrealIDs > 0) {
			my $includedVLIDstring = join(',', @includedVLIBrealIDs);
			$sql =~ s/\'VLCincludedVLs\'/$includedVLIDstring/g;
		}
	}

	# excluded virtual libraries
	if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'}) {
		$log->debug('excludedvlids = '.Dumper($virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'}));
		my @excludedVLIBrealIDs = ();
		foreach (split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'})) {
			my $VLrealID = Slim::Music::VirtualLibraries->getRealId($_);
			if ($VLrealID) {
				$log->debug("Will replace permanent virtual library ID '$_' with current real ID '$VLrealID'.");
				push @excludedVLIBrealIDs, Slim::Schema->storage->dbh()->quote(Slim::Music::VirtualLibraries->getRealId($_));
			} else {
				$log->error("The virtual library '$_' of your parameter 'excluded virtual libraries' in your virtual library '".$virtualLibraries->{$thisVLCvirtualLibrary}->{'name'}."' does not exist. Your virtual library definition will not work (correctly).");
			}
		}
		if (scalar @excludedVLIBrealIDs > 0) {
			my $excludedVLIDstring = join(',', @excludedVLIBrealIDs);
			$sql =~ s/\'VLCexcludedVLs\'/$excludedVLIDstring/g;
		}
	}

	if ($sql ne $sqlCmp) {
		$log->debug('sql = '.Dumper($sqlCmp));
		$log->debug('sql with replaced params = '.Dumper($sql));
	}
	return $sql;
}

sub manualVLrefresh {
	$log->info('Deregister and then recreate all VLC virtual libraries and menus.');
	my $postScanCall = 1;
	setRefreshCBTimer();
}

sub dailyVLrefreshScheduler {
	my $recentlyCreatedVLIDs = shift;
	$log->debug('Recently created VLs = '.Dumper($recentlyCreatedVLIDs));

	if ($prefs->get('vlstempdisabled')) {
		$log->info('Scheduled refresh is disabled as long as VLC VLs are globally disabled/paused.');
		$log->debug('Killing existing timers for scheduled VL refresh');
		Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
		return;
	}

	# get list of enabled VLs that ask for daily refresh
	my @dailyRefreshVLIDs = ();
	foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
		my $enabled = $virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
		my $dailyVLrefresh = $virtualLibraries->{$thisVLCvirtualLibrary}->{'dailyvlrefresh'};
		next if (!$enabled || !$dailyVLrefresh);
		push @dailyRefreshVLIDs, $virtualLibraries->{$thisVLCvirtualLibrary}->{'VLID'};
	}
	$log->debug('dailyRefreshVLIDs = '.Dumper(\@dailyRefreshVLIDs));

	# schedule refresh if requested
	if (scalar @dailyRefreshVLIDs > 0) {
		$log->debug('These enabled VLs request a daily refresh: '.Dumper(\@dailyRefreshVLIDs));
		$log->debug('Killing existing timers for scheduled VL refresh');
		Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
		my ($dailyVLrefreshTimeUnparsed, $dailyVLrefreshTime);
		$dailyVLrefreshTimeUnparsed = $dailyVLrefreshTime = $prefs->get('dailyvlrefreshtime');

		if (defined($dailyVLrefreshTime) && $dailyVLrefreshTime ne '') {
			my $time = 0;
			my $lastRefreshDay = $prefs->get('lastscheduledrefresh_day');
			if (!defined($lastRefreshDay)) {
				$lastRefreshDay = '';
			}
			$dailyVLrefreshTime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;

			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
			my $currentTime = $hour * 60 * 60 + $min * 60;

			if (($lastRefreshDay ne $mday) && ($currentTime >= $dailyVLrefreshTime)) {
				$log->info('Last refresh day was '.($lastRefreshDay ? 'on day '.$lastRefreshDay : 'never').'. Refreshing eligible VLs now.');
				my $started = time();

				foreach my $thisVLID (@dailyRefreshVLIDs) {
					if ($recentlyCreatedVLIDs && ref($recentlyCreatedVLIDs) eq 'HASH' && $recentlyCreatedVLIDs->{$thisVLID}) {
						$log->info("Skipping refresh for VL '$thisVLID because it's just been created.");
						next;
					}
					my $VLexists = Slim::Music::VirtualLibraries->getRealId($thisVLID);
					Slim::Music::VirtualLibraries->rebuild($VLexists) if $VLexists;
					$log->info("Refreshed VL '$thisVLID'.") if $VLexists;;
				}

				my $ended = time() - $started;
				$log->info('Scheduled refresh of selected virtual libraries completed after '.$ended.' seconds.');
				$prefs->set('lastscheduledrefresh_day', $mday);
				Slim::Utils::Timers::setTimer(undef, time() + 120, \&dailyVLrefreshScheduler);
			} else {
				my $timeleft = $dailyVLrefreshTime - $currentTime;
				if ($lastRefreshDay eq $mday) {
					$timeleft = $timeleft + 24 * 60 * 60;
				}
				$log->info(parse_duration($timeleft)." until next scheduled VL refresh at ".$dailyVLrefreshTimeUnparsed);
				Slim::Utils::Timers::setTimer(undef, time() + $timeleft, \&dailyVLrefreshScheduler);
			}
		} else {
			$log->warn('dailyVLrefreshTime = not defined or empty string');
		}

	} else {
		$log->debug('Killing existing timers for scheduled VL refresh');
		Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
		$log->info('Found no VLs requesting daily refresh.')
	}
}

sub initHomeVLMenus {
	$log->debug('Started initializing HOME VL menus.');
	my $started = time();

	if (keys %{$virtualLibraries} > 0) {
		### get enabled browse menus for home menu
		my @enabledHomeBrowseMenus = ();
		foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
			next if !$virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
			my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
			my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($VLCitemID)) if defined $VLCitemID && $VLCitemID ne '';
			$log->debug('VLID = '.Dumper($VLID));
			my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
			next if !$library_id;

			if (($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'})) {
					push @enabledHomeBrowseMenus, $thisVLCvirtualLibrary;
			}
		}
		$log->debug('enabled home menu browse menus = '.scalar(@enabledHomeBrowseMenus)."\n".Dumper(\@enabledHomeBrowseMenus));

		### create browse menus for home folder
		if (scalar @enabledHomeBrowseMenus > 0) {
			my @homeBrowseMenus = ();

			foreach my $thisVLCvirtualLibrary (sort @enabledHomeBrowseMenus) {
				my $enabled = $virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
				next if !$enabled;
				my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
				my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($VLCitemID)) if defined $VLCitemID && $VLCitemID ne '';
				$log->debug('VLID = '.Dumper($VLID));

				my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
				next if !$library_id;

				if (defined $enabled && defined $library_id) {
					my $browsemenu_name = $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'};
					$log->debug('browsemenu_name = '.$browsemenu_name);

					# get menus from browse menu strings
					my %artistMenus = ();
					if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) {
						my @selArtistMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'});
						%artistMenus = map {$_ => 1} @selArtistMenus;
						$log->debug('selectedArtistMenus = '.Dumper(\%artistMenus));
					}
					my $artistHomeMenusWeight = $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenuweight'};

					my %albumMenus = ();
					if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) {
						my @selAlbumMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'});
						%albumMenus = map {$_ => 1} @selAlbumMenus;
						$log->debug('selectedAlbumMenus = '.Dumper(\%albumMenus));
					}
					my $albumHomeMenusWeight = $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenuweight'};

					my %miscMenus = ();
					if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'}) {
						my @selMiscMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'});
						%miscMenus = map {$_ => 1} @selMiscMenus;
						$log->debug('selectedMiscMenus = '.Dumper(\%miscMenus));
					}
					my $miscHomeMenusWeight = $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenuweight'};

					### ARTISTS MENUS ###

					# user configurable list of artists
					if ($artistMenus{1}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_ALLARTISTS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $artistHomeMenusWeight ? $artistHomeMenusWeight : 209,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id}
						};
					}

					# Album artists
					if ($artistMenus{5}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_ALBUMARTISTS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $artistHomeMenusWeight ? $artistHomeMenusWeight + 1 : 210,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'ALBUMARTIST'}
						};
					}

					# Composers
					if ($artistMenus{2}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_COMPOSERS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $artistHomeMenusWeight ? $artistHomeMenusWeight + 2 : 211,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'COMPOSER'}
						};
					}

					# Conductors
					if ($artistMenus{3}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_CONDUCTORS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $artistHomeMenusWeight ? $artistHomeMenusWeight + 3 : 212,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'CONDUCTOR'}
						};
					}

					# Track Artists
					if ($artistMenus{6}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_TRACKARTISTS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $artistHomeMenusWeight ? $artistHomeMenusWeight + 4 : 213,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'TRACKARTIST'}
						};
					}

					# Bands
					if ($artistMenus{4}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_BANDS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $artistHomeMenusWeight ? $artistHomeMenusWeight + 5 : 214,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'BAND'}
						};
					}

					### ALBUMS MENUS ###

					# All albums
					if ($albumMenus{1}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'html/images/albums.png',
							jiveIcon => 'html/images/albums.png',
							id => $VLID.'_BROWSEMENU_HOME_ALLALBUMS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight : 215,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_albums,
							params => {library_id => $library_id},
						};
					}

					# All albums by genre
					if ($albumMenus{2}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSBYGENRE'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
							jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
							id => $VLID.'_BROWSEMENU_HOME_ALLALBUMSBYGENRE',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 1 : 216,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_genres,
							params => {library_id => $library_id,
										mode => 'genres',
										sort => 'title',
							},
						};
					}

					# Random Albums
					if ($albumMenus{3}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
							jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
							id => $VLID.'_BROWSEMENU_HOME_RANDOMALBUMS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 2 : 217,
							cache => 0,
							feed => \&Slim::Menu::BrowseLibrary::_albums,
							params => {library_id => $library_id,
										mode => 'randomalbums',
										sort => 'random',
									},
						};
					}

					# Albums without compilations
# 					if ($albumMenus{4}) {
# 						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS'));
# 						push @homeBrowseMenus,{
# 							type => 'link',
# 							name => $menuString,
# 							homeMenuText => $menuString,
# 							icon => 'html/images/albums.png',
# 							jiveIcon => 'html/images/albums.png',
# 							id => $VLID.'_BROWSEMENU_HOME_NOCOMPIS',
# 							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
# 							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 3 : 218,
# 							cache => 1,
# 							feed => \&Slim::Menu::BrowseLibrary::_albums,
# 							params => {library_id => $library_id,
# 										compilation => '0 || null' },
# 						};
# 					}

					# Compilations only
					if ($albumMenus{5}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'html/images/albums.png',
							jiveIcon => 'html/images/albums.png',
							id => $VLID.'_BROWSEMENU_HOME_COMPISONLY',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 4 : 219,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_albums,
							params => {library_id => $library_id,
										artist_id => Slim::Schema->variousArtistsObject->id,
										mode => 'vaalbums',
										compilation => 1 },
						};
					}

					# Random compilations
					if ($albumMenus{6}) {
						my $menuString = lc($browsemenu_name) eq lc('Compilations random') ? registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS_HOMEDISPLAYED')) : registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
							jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
							id => $VLID.'_BROWSEMENU_HOME_RANDOMCOMPIS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 5 : 220,
							cache => 0,
							feed => \&Slim::Menu::BrowseLibrary::_albums,
							params => {library_id => $library_id,
										artist_id => Slim::Schema->variousArtistsObject->id,
										mode => 'randomalbums',
										sort => 'random',
										compilation => 1 },
						};
					}

					# Compilations by genre
					if ($albumMenus{7}) {
						my $menuString = lc($browsemenu_name) eq lc('Compilations by genre') ? registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE_HOMEDISPLAYED')) : registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							mode => 'vaalbums',
							icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
							jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
							id => $VLID.'_BROWSEMENU_HOME_COMPISBYGENRE',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 6 : 221,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_genres,
							params => {library_id => $library_id,
										artist_id => Slim::Schema->variousArtistsObject->id,
										mode => 'genres',
										sort => 'title',
										compilation => 1 },
						};
					}

					# Compilations by year
					if ($albumMenus{8}) {
						my $menuString = lc($browsemenu_name) eq lc('Compilations by year') ? registerCustomString(string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR')) : registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							mode => 'vaalbums',
							icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png',
							jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png',
							id => $VLID.'_BROWSEMENU_HOME_COMPISBYYEAR',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $albumHomeMenusWeight ? $albumHomeMenusWeight + 7 : 222,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_years,
							params => {library_id => $library_id,
										artist_id => Slim::Schema->variousArtistsObject->id,
										mode => 'years',
										sort => 'title',
										compilation => 1 },
						};
					}

					### OTHER MENUS ###

					# Genres menu
					if ($miscMenus{1}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'html/images/genres.png',
							jiveIcon => 'html/images/genres.png',
							id => $VLID.'_BROWSEMENU_GENRE_ALL',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $miscHomeMenusWeight ? $miscHomeMenusWeight : 223,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_genres,
							params => {library_id => $library_id}
						};
					}

					# Years menu
					if ($miscMenus{2}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'html/images/years.png',
							jiveIcon => 'html/images/years.png',
							id => $VLID.'_BROWSEMENU_YEARS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $miscHomeMenusWeight ? $miscHomeMenusWeight + 2 : 225,
							cache => 1,
							feed => \&Slim::Menu::BrowseLibrary::_years,
							params => {library_id => $library_id}
						};
					}

					# Just Tracks Menu
					if ($miscMenus{3}) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							homeMenuText => $menuString,
							icon => 'html/images/playlists.png',
							jiveIcon => 'html/images/playlists.png',
							id => $VLID.'_BROWSEMENU_TRACKS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $miscHomeMenusWeight ? $miscHomeMenusWeight + 4 : 227,
							cache => 1,
							playlist => \&Slim::Menu::BrowseLibrary::_tracks,
							feed => \&Slim::Menu::BrowseLibrary::_tracks,
							params => {library_id => $library_id}
						};
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

	$log->debug('Finished initializing home VL browse menus after '.(time() - $started).' secs.');
	initCollectedVLMenus();
	}
}

sub initCollectedVLMenus {
	$log->debug('Started initializing collected VL menus.');
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
			$log->debug('VLID = '.Dumper($VLID));
			my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
			next if !$library_id;

			if (($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) ||
				($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'})) {
					push @enabledCollectedBrowseMenus, $thisVLCvirtualLibrary;
			}
		}
		$log->debug('enabled browse menus collected in VLC parent folder = '.scalar(@enabledCollectedBrowseMenus)."\n".Dumper(\@enabledCollectedBrowseMenus));

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
			$log->debug('browsemenus_parentfoldericon = '.$browsemenus_parentfoldericon);
			$log->debug('iconPath = '.$iconPath);

			Slim::Menu::BrowseLibrary->registerNode({
				type => 'link',
				name => $nameToken,
				id => $browsemenus_parentfolderID,
				feed => sub {
					my ($client, $cb, $args, $pt) = @_;
					my @collectedBrowseMenus = ();
					foreach my $thisVLCvirtualLibrary (sort @enabledCollectedBrowseMenus) {
						my $VLID = 'PLUGIN_VLC_VLID_'.trim_all(uc($virtualLibraries->{$thisVLCvirtualLibrary}->{'id'}));
						$log->debug('VLID = '.Dumper($VLID));
						my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
						my $pt = {library_id => $library_id};
						my $browsemenu_name = $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'};
						$log->debug('browsemenu_name = '.$browsemenu_name);

						# get menus from browse menu strings
						my %artistMenus = ();
						if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenushomemenu'}) {
							my @selArtistMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'artistmenus'});
							%artistMenus = map {$_ => 1} @selArtistMenus;
							$log->debug('selectedArtistMenus = '.Dumper(\%artistMenus));
						}

						my %albumMenus = ();
						if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenushomemenu'}) {
							my @selAlbumMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'albummenus'});
							%albumMenus = map {$_ => 1} @selAlbumMenus;
							$log->debug('selectedAlbumMenus = '.Dumper(\%albumMenus));
						}

						my %miscMenus = ();
						if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'} && !$virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenushomemenu'}) {
							my @selMiscMenus = split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'miscmenus'});
							%miscMenus = map {$_ => 1} @selMiscMenus;
							$log->debug('selectedMiscMenus = '.Dumper(\%miscMenus));
						}

						### ARTISTS MENUS ###

						# user configurable list of artists
						if ($artistMenus{1}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ARTISTS'),
								icon => 'html/images/artists.png',
								jiveIcon => 'html/images/artists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_ALLARTISTS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 209,
								cache => 1,
								url => sub {
									my ($client, $callback, $args, $pt) = @_;
									Slim::Menu::BrowseLibrary::_artists($client,
										sub {
												my $items = shift;
												$log->debug("Browsing artists");
												if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
													$items->{items} = [ map {
															$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
															$_;
													} @{$items->{items}} ];
												}
											$callback->($items);
										}, $args, $pt);
									},
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										#'role_id:'.join ',', Slim::Schema::Contributor->contributorRoles()
									],
								}],
							};
						}

						# Album artists
						if ($artistMenus{5}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALBUMARTISTS'),
								icon => 'html/images/artists.png',
								jiveIcon => 'html/images/artists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_ALBUMARTISTS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 210,
								cache => 1,
								url => sub {
									my ($client, $callback, $args, $pt) = @_;
									Slim::Menu::BrowseLibrary::_artists($client,
										sub {
												my $items = shift;
												$log->debug("Browsing artists");
												if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
													$items->{items} = [ map {
															$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
															$_;
													} @{$items->{items}} ];
												}
											$callback->($items);
										}, $args, $pt);
									},
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:ALBUMARTIST'
									],
								}],
							};
						}

						# Composers
						if ($artistMenus{2}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPOSERS'),
								icon => 'html/images/artists.png',
								jiveIcon => 'html/images/artists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_COMPOSERS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 211,
								cache => 1,
								url => sub {
									my ($client, $callback, $args, $pt) = @_;
									Slim::Menu::BrowseLibrary::_artists($client,
										sub {
												my $items = shift;
												$log->debug("Browsing artists");
												if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
													$items->{items} = [ map {
															$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
															$_;
													} @{$items->{items}} ];
												}
											$callback->($items);
										}, $args, $pt);
									},
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:COMPOSER'
									],
								}],
							};
						}

						# Conductors
						if ($artistMenus{3}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_CONDUCTORS'),
								icon => 'html/images/artists.png',
								jiveIcon => 'html/images/artists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_CONDUCTORS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 212,
								cache => 1,
								url => sub {
									my ($client, $callback, $args, $pt) = @_;
									Slim::Menu::BrowseLibrary::_artists($client,
										sub {
												my $items = shift;
												$log->debug("Browsing artists");
												if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
													$items->{items} = [ map {
															$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
															$_;
													} @{$items->{items}} ];
												}
											$callback->($items);
										}, $args, $pt);
									},
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:CONDUCTOR'
									],
								}],
							};
						}

						# Track Artists
						if ($artistMenus{6}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKARTISTS'),
								icon => 'html/images/artists.png',
								jiveIcon => 'html/images/artists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_TRACKARTISTS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 213,
								cache => 1,
								url => sub {
									my ($client, $callback, $args, $pt) = @_;
									Slim::Menu::BrowseLibrary::_artists($client,
										sub {
												my $items = shift;
												$log->debug("Browsing artists");
												if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
													$items->{items} = [ map {
															$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
															$_;
													} @{$items->{items}} ];
												}
											$callback->($items);
										}, $args, $pt);
									},
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:TRACKARTIST'
									],
								}],
							};
						}

						# Bands
						if ($artistMenus{4}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_BANDS'),
								icon => 'html/images/artists.png',
								jiveIcon => 'html/images/artists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_BANDS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 214,
								cache => 1,
								url => sub {
									my ($client, $callback, $args, $pt) = @_;
									Slim::Menu::BrowseLibrary::_artists($client,
										sub {
												my $items = shift;
												$log->debug("Browsing artists");
												if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
													$items->{items} = [ map {
															$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
															$_;
													} @{$items->{items}} ];
												}
											$callback->($items);
										}, $args, $pt);
									},
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'role_id:BAND'
									],
								}],
							};
						}

						### ALBUMS MENUS ###

						# All albums
						if ($albumMenus{1}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMS'),
								icon => 'html/images/albums.png',
								jiveIcon => 'html/images/albums.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_ALLALBUMS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 215,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_albums,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}],
							};
						}

						# All albums by genre
						if ($albumMenus{2}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
									mode => 'albums',
									sort => 'title',
							};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSBYGENRE'),
								icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
								jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_ALLALBUMSBYGENRE',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 216,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_genres,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'mode:'.$pt->{'mode'},
										'sort:'.$pt->{'sort'},
									],
								}],
							};
						}

						# Random Albums
						if ($albumMenus{3}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
									mode => 'randomalbums',
									sort => 'random',
							};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_ALLALBUMSRANDOM'),
								icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
								jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_RANDOMALBUMS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 217,
								cache => 0,
								url => \&Slim::Menu::BrowseLibrary::_albums,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'mode:'.$pt->{'mode'},
										'sort:'.$pt->{'sort'},
									],
								}],
							};
						}

						# Albums without compilations
						if ($albumMenus{4}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_NOCOMPIS'),
								icon => 'html/images/albums.png',
								jiveIcon => 'html/images/albums.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_NOCOMPIS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 218,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_albums,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'compilation: 0 || null',
									],
								}],
							};
						}

						# Compilations only
						if ($albumMenus{5}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
									artist_id => Slim::Schema->variousArtistsObject->id,
									compilation => 1,
							};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISONLY'),
								mode => 'vaalbums',
								icon => 'html/images/albums.png',
								jiveIcon => 'html/images/albums.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_COMPISONLY',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 219,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_albums,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'artist_id'},
										'compilation:'.$pt->{'compilation'},
									],
								}],
							};
						}

						# Random compilations
						if ($albumMenus{6}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
									artist_id => Slim::Schema->variousArtistsObject->id,
									mode => 'vaalbums',
									sort => 'random',
									compilation => 1,
							};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_RANDOMCOMPIS'),
								mode => 'vaalbums',
								icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
								jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-randomalbums_svg.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_RANDOMCOMPIS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 220,
								cache => 0,
								url => \&Slim::Menu::BrowseLibrary::_albums,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'artist_id'},
										'compilation:'.$pt->{'compilation'},
										'mode:'.$pt->{'mode'},
										'sort:'.$pt->{'sort'},
									],
								}],
							};
						}

						# Compilations by genre
						if ($albumMenus{7}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
									artist_id => Slim::Schema->variousArtistsObject->id,
									mode => 'vaalbums',
									sort => 'title',
									compilation => 1,
							};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYGENRE'),
								mode => 'vaalbums',
								icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
								jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbygenre_svg.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_COMPISBYGENRE',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 221,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_genres,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'artist_id'},
										'compilation:'.$pt->{'compilation'},
										'mode:'.$pt->{'mode'},
										'sort:'.$pt->{'sort'},
									],
								}],
							};
						}

						# Compilations by year
						if ($albumMenus{8}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
									artist_id => Slim::Schema->variousArtistsObject->id,
									mode => 'vaalbums',
									sort => 'title',
									compilation => 1,
							};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_COMPISBYYEAR'),
								mode => 'vaalbums',
								icon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png',
								jiveIcon => 'plugins/VirtualLibraryCreator/html/images/browsemenu-albumsbyyear_svg.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_COMPISBYYEAR',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 222,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_years,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
										'artist_id:'.$pt->{'artist_id'},
										'compilation:'.$pt->{'compilation'},
										'mode:'.$pt->{'mode'},
										'sort:'.$pt->{'sort'},
									],
								}],
							};
						}

						### OTHER MENUS ###

						# Genres menu
						if ($miscMenus{1}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_GENRES'),
								icon => 'html/images/genres.png',
								jiveIcon => 'html/images/genres.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_GENRE_ALL',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 226,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_genres,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}],
							};
						}

						# Years menu
						if ($miscMenus{2}) {
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_YEARS'),
								icon => 'html/images/years.png',
								jiveIcon => 'html/images/years.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_YEARS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 227,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_years,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'}
									],
								}],
							};
						}

						# Just Tracks Menu
						if ($miscMenus{3}) {
							$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID)};
							push @collectedBrowseMenus,{
								type => 'link',
								name => $browsemenu_name.' - '.string('PLUGIN_VIRTUALLIBRARYCREATOR_BROWSEMENUS_TRACKS'),
								icon => 'html/images/playlists.png',
								jiveIcon => 'html/images/playlists.png',
								id => $VLID.'_BROWSEMENU_COLLECTED_TRACKS',
								condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
								weight => 228,
								cache => 1,
								url => \&Slim::Menu::BrowseLibrary::_tracks,
								passthrough => [{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
									],
								}],
							};
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

	$log->debug('Finished initializing collected VL browse menus after '.(time() - $started).' secs.');
	}
}

sub deregAllMenus {
	my $nodeList = Slim::Menu::BrowseLibrary->_getNodeList();
	$log->debug('node list = '.Dumper($nodeList));

	foreach my $homeMenuItem (@{$nodeList}) {
		if (starts_with($homeMenuItem->{'id'}, 'PLUGIN_VLC_VL') == 0) {
			$log->debug('Deregistering home menu item: '.Dumper($homeMenuItem->{'id'}));
			Slim::Menu::BrowseLibrary->deregisterNode($homeMenuItem->{'id'});
		}
	}
}

sub getVLCvirtualLibraryList {
	my $client = shift;
	my @pluginDirs = ();

	my $itemConfiguration = getConfigManager()->readItemConfiguration($client, 1);
	$webVirtualLibraries = $itemConfiguration->{'webvirtuallibraries'};
	$virtualLibraries = $itemConfiguration->{'virtuallibraries'};

	$log->debug('web virtual libraries = '.Dumper($webVirtualLibraries));
	$log->debug('virtual libraries = '.Dumper($virtualLibraries));
}

sub setRefreshCBTimer {
	my $recreateChangedVL = shift;

	$log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killTimers($recreateChangedVL, \&initVirtualLibrariesDelayed);
	$log->debug('Scheduling a delayed'.($isPostScanCall ? ' post-scan' : '').' refresh');
	Slim::Utils::Timers::setTimer($recreateChangedVL, Time::HiRes::time() + $prefs->get('scheduledinitdelay'), \&initVirtualLibrariesDelayed);
}

sub initVirtualLibrariesDelayed {
	my $recreateChangedVL = shift;

	if (Slim::Music::Import->stillScanning) {
		$log->debug('Scan in progress. Waiting for current scan to finish.');
		setRefreshCBTimer();
	} else {
		$log->debug('Starting delayed VL init');
		refreshSQLCache() if $isPostScanCall;
		initVirtualLibraries($recreateChangedVL);
	}
}

sub getConfigManager {
	if (!defined($configManager)) {
		my %parameters = (
			'pluginVersion' => $pluginVersion,
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
	$log->debug('VL refresh required = '.Dumper($params->{'vlrefresh'}));
	$log->debug('New or edited VL = '.Dumper($params->{'changedvl'}));

	setRefreshCBTimer($params->{'changedvl'}) if $params->{'vlrefresh'};

	# get VLs for web display
	my @webVLs = ();
	for my $key (keys %{$webVirtualLibraries}) {
		push @webVLs, $webVirtualLibraries->{$key};
	}
	@webVLs = sort {uc($a->{'name'}) cmp uc($b->{'name'})} @webVLs;
	$log->debug('webVLs = '.Dumper(\@webVLs));
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
	$log->debug('VLS temp. disabled = '.Dumper($params->{'globallydisabled'}));

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
	$log->debug('Current temp. disabled state = '.Dumper($tmpDisabledState));

	$tmpDisabledState = $prefs->set('vlstempdisabled', ($tmpDisabledState ? 0 : 1));
	$log->debug('New temp. disabled state = '.Dumper($tmpDisabledState));
	$params->{'vlrefresh'} = 1; # 1 = all VLs temp. globally disabled/paused, 2 = new VL, 3 = edited VL, 4 = deleted VL
	handleWebList($client, $params);
}


sub createVirtualLibrariesFolder {
	my $virtualLibrariesFolder_parentfolderpath = $prefs->get('customdirparentfolderpath') || $serverPrefs->get('playlistdir');
	my $virtualLibrariesFolder = catdir($virtualLibrariesFolder_parentfolderpath, 'VirtualLibraryCreator');
	eval {
		mkdir($virtualLibrariesFolder, 0755) unless (-d $virtualLibrariesFolder);
		chdir($virtualLibrariesFolder);
	} or do {
		$log->error("Could not create or access VirtualLibraryCreator folder in parent folder '$virtualLibrariesFolder_parentfolderpath'!");
		return;
	};
	$prefs->set('customvirtuallibrariesfolder', $virtualLibrariesFolder);
}

sub getVirtualLibraries {
	my (@items, @hiddenVLs);
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	$log->debug('ALL virtual libraries: '.Dumper($libraries));

	while (my ($key, $values) = each %{$libraries}) {
		my $count = Slim::Music::VirtualLibraries->getTrackCount($key);
		my $name = $values->{'name'};
		my $displayName = Slim::Utils::Unicode::utf8decode($name, 'utf8').' ('.Slim::Utils::Misc::delimitThousands($count).($count == 1 ? ' track' : ' tracks').')';
		$log->debug("VL: ".$displayName);
		my $persistentVLID = $values->{'id'};

		push @items, {
			name => $displayName,
			sortName => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
			value => $persistentVLID,
			id => $persistentVLID,
		};
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
	my $type = shift || 'misc';
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
	return \@result;
}

sub getVLBrowseMenusArtists {
	return getVLBrowseMenus('artists');
}

sub getVLBrowseMenusAlbums {
	return getVLBrowseMenus('albums');
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

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub registerCustomString {
	my $string = shift;
	$log->debug('string = '.Dumper($string));

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

sub starts_with {
	# complete_string, start_string, position
	return rindex($_[0], $_[1], 0);
	# returns 0 for yes, -1 for no
}

sub refreshSQLCache {
	$log->debug('Deleting old caches and creating new ones');
	$cache->remove('vlc_pluginversion');
	$cache->remove('vlc_contributorlist_all');
	$cache->remove('vlc_contributorlist_albumartists');
	$cache->remove('vlc_contributorlist_composers');
	$cache->remove('vlc_genrelist');
	$cache->remove('vlc_contenttypes');

	my $contributorSQL_all = "select contributors.id,contributors.name,contributors.namesearch from tracks,contributor_track,contributors where tracks.id=contributor_track.track and contributor_track.contributor=contributors.id and contributor_track.role in (1,5,6) group by contributors.id order by contributors.namesort asc";
	my $contributorSQL_albumartists = "select contributors.id,contributors.name,contributors.namesearch from tracks,contributor_track,contributors where tracks.id=contributor_track.track and contributor_track.contributor=contributors.id and contributor_track.role in (1,5) group by contributors.id order by contributors.namesort asc";
	my $contributorSQL_composers = "select contributors.id,contributors.name,contributors.namesearch from tracks,contributor_track,contributors where tracks.id=contributor_track.track and contributor_track.contributor=contributors.id and contributor_track.role = 2 group by contributors.id order by contributors.namesort asc";
	my $genreSQL = "select genres.id,genres.name,genres.namesearch from genres order by namesort asc";
	my $contentTypesSQL = "select distinct tracks.content_type,tracks.content_type,tracks.content_type from tracks where tracks.content_type is not null and tracks.content_type != 'cpl' and tracks.content_type != 'src' and tracks.content_type != 'ssp' and tracks.content_type != 'dir' order by tracks.content_type asc";

	my $contributorList_all = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contributorSQL_all);
	$cache->set('vlc_contributorlist_all', $contributorList_all, 'never');
	$log->debug('contributorList_all count = '.scalar(@{$contributorList_all}));

	my $contributorList_albumartists = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contributorSQL_albumartists);
	$cache->set('vlc_contributorlist_albumartists', $contributorList_albumartists, 'never');
	$log->debug('contributorList_albumartists count = '.scalar(@{$contributorList_albumartists}));

	my $contributorList_composers = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contributorSQL_composers);
	$cache->set('vlc_contributorlist_composers', $contributorList_composers, 'never');
	$log->debug('contributorList_composers count = '.scalar(@{$contributorList_composers}));

	my $genreList = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $genreSQL);
	$cache->set('vlc_genrelist', $genreList, 'never');
	$log->debug('genreList count = '.scalar(@{$genreList}));

	my $contentTypesList = Plugins::VirtualLibraryCreator::ConfigManager::ParameterHandler::getSQLTemplateData(undef, $contentTypesSQL);
	$cache->set('vlc_contenttypes', $contentTypesList, 'never');
	$log->debug('contentTypesList count = '.scalar(@{$contentTypesList}));

	$cache->set('vlc_pluginversion', $pluginVersion);
}

*escape = \&URI::Escape::uri_escape_utf8;

sub unescape {
	my ($in, $isParam) = @_;
	$in =~ s/\+/ /g if $isParam;
	$in =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
	return $in;
}

1;
