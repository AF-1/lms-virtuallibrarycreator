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

package Plugins::VirtualLibraryCreator::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use File::Spec::Functions qw(:ALL);
use POSIX qw(floor);
use Time::HiRes qw(time);

my $prefs = preferences('plugin.virtuallibrarycreator');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.virtuallibrarycreator');

use Plugins::VirtualLibraryCreator::ConfigManager::Main;

my $virtualLibraries = undef;
my $configManager = undef;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(initVirtualLibraries dailyVLrefreshScheduler commit rollback starts_with)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );


sub initVirtualLibraries {
	my ($importerCall, $recreateChangedVL) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Start initializing VLs.');
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
				main::DEBUGLOG && $log->is_debug && $log->debug('baseLibrariesVLIDs = '.Data::Dump::dump(\%baseLibrariesVLIDs));


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
	main::DEBUGLOG && $log->is_debug && $log->debug('virtual libraries = '.Data::Dump::dump($virtualLibraries));

	my $LMS_virtuallibraries = Slim::Music::VirtualLibraries->getLibraries();
	main::DEBUGLOG && $log->is_debug && $log->debug('Found these registered LMS virtual libraries: '.Data::Dump::dump($LMS_virtuallibraries));

	## unregister virtual libraries if globally disabled, post-scan call or manual refresh
	if ($prefs->get('vlstempdisabled') || $importerCall || $prefs->get('manualrefresh')) {
		my $VLunregCount = 0;
		foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
			my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
			main::DEBUGLOG && $log->is_debug && $log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'PLUGIN_VLC_VLID_') == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
				$VLunregCount++;
			}
		}

		if ($prefs->get('vlstempdisabled')) {
			main::INFOLOG && $log->is_info && $log->info('VLC VLs globally disabled/paused.'.($VLunregCount ? ' Unregistering all VLC VLs.' : '')) if $prefs->get('vlstempdisabled');
			Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
			return;
		}
		if ($importerCall) {
			main::INFOLOG && $log->is_info && $log->info('Post-scan init.'.($VLunregCount ? ' Unregistering all VLC VLs.' : ''));
		} elsif ($prefs->get('manualrefresh')) {
			$prefs->set('manualrefresh', 0);
			main::INFOLOG && $log->is_info && $log->info('Forced manual refresh.'.($VLunregCount ? ' Unregistering all VLC VLs.' : ''));
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Number of VLC virtual libraries = '.Data::Dump::dump(keys %{$virtualLibraries}));

	### create/register VLs
	if (keys %{$virtualLibraries} > 0) {
		my ($progress, $countEnabled);

		if (!$importerCall) { # VLs have already been unregistered if importerCall
			# unregister VLC virtual libraries that are disabled or no longer exist
			foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
				my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
				main::DEBUGLOG && $log->is_debug && $log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
				if (starts_with($thisVLID, 'PLUGIN_VLC_VLID_') == 0) {
					my $isVLClibrary = 0;
					foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
						next if (!defined ($virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'}));
						my $VLID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'VLID'};
						if ($VLID eq $thisVLID) {
								main::DEBUGLOG && $log->is_debug && $log->debug("VL '$VLID' is already registered and still part of VLC VLs.");
								$isVLClibrary = 1;
						}
					}
					if ($isVLClibrary == 0) {
						main::INFOLOG && $log->is_info && $log->info("VL '$thisVLID' is disabled or was deleted from VLC. Unregistering VL.");
						Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
					}
				}
			}
		} else {
			$countEnabled = 0;
			foreach (keys %{$virtualLibraries}) {
				$countEnabled++ if $virtualLibraries->{$_}->{'enabled'};
			}
			main::INFOLOG && $log->is_info && $log->info('Number of enabled VLC libraries: '.Data::Dump::dump($countEnabled));

			if ($countEnabled) {
				$progress = Slim::Utils::Progress->new({
					'type' => 'importer',
					'name' => 'plugin_virtuallibrarycreator_vlrecreation',
					'total' => $countEnabled,
					'bar' => 1
				});
			}
		}

		# create/register enabled VLs not yet registered
		my %recentlyCreatedVLIDs = ();

		foreach my $thisVLCvirtualLibrary (sort { ($virtualLibraries->{$a}->{'libraryinitorder'} || 0) <=> ($virtualLibraries->{$b}->{'libraryinitorder'} || 0)} keys %{$virtualLibraries}) {
			my $enabled = $virtualLibraries->{$thisVLCvirtualLibrary}->{'enabled'};
			next if !defined($enabled);

			my $VLCitemID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'id'};
			main::DEBUGLOG && $log->is_debug && $log->debug('item ID = '.$VLCitemID);
			my $VLID = $virtualLibraries->{$thisVLCvirtualLibrary}->{'VLID'};
			main::DEBUGLOG && $log->is_debug && $log->debug('VLID = '.$VLID);
			my $libraryInitOrder = $virtualLibraries->{$thisVLCvirtualLibrary}->{'libraryinitorder'};
			main::DEBUGLOG && $log->is_debug && $log->debug('libraryInitOrder = '.Data::Dump::dump($libraryInitOrder));

			my $browsemenu_name = $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'};
			main::DEBUGLOG && $log->is_debug && $log->debug('browsemenu_name = '.$browsemenu_name);

			my $sql = replaceParametersInSQL($thisVLCvirtualLibrary); # replace parameters if necessary
			main::DEBUGLOG && $log->is_debug && $log->debug('sql = '.$sql);
			my $sqlstatement = qq{$sql};

			my $library = {
				id => $VLID,
				name => $browsemenu_name,
				sql => $sqlstatement,
			};

			# if we have a recently edited VL, unregister it so it can be recreated
			if ($recreateChangedVL && $recreateChangedVL eq $VLCitemID) {
				main::INFOLOG && $log->is_info && $log->info("Request to (re)create VL '$VLID'");
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id}, 1);
			}

			my $VLalreadyexists = Slim::Music::VirtualLibraries->getRealId($VLID);
			main::DEBUGLOG && $log->is_debug && $log->debug('Check if VL already exists. Returned real library id = '.Data::Dump::dump($VLalreadyexists));
			if (defined $VLalreadyexists) {
				main::DEBUGLOG && $log->is_debug && $log->debug("VL '$VLID' already exists.");
				next;
			}

			main::DEBUGLOG && $log->is_debug && $log->debug("VL '$VLID' has not been created yet. Creating & registering it now.");
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

			if ($prefs->get('hidezerotrackvls')) {
				my $trackCount = Slim::Music::VirtualLibraries->getTrackCount($VLID);
				main::DEBUGLOG && $log->is_debug && $log->debug("track count vlib '$browsemenu_name' = ".Data::Dump::dump($trackCount));
				if ($trackCount == 0) {
					Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
					main::INFOLOG && $log->is_info && $log->info("Unregistering vlib '$browsemenu_name' because it has 0 tracks.");
				}
			}
			$progress->update() if $importerCall;
			main::idleStreams();
		}

		# check if there are VLs that request a daily refresh
		dailyVLrefreshScheduler(\%recentlyCreatedVLIDs);

		$progress->final($countEnabled) if $importerCall && $progress;
	}

	main::INFOLOG && $log->is_info && $log->info('Finished initializing virtual libraries after '.(time() - $started).' secs.');
}

sub replaceParametersInSQL {
	my $thisVLCvirtualLibrary = shift;
	my %replaceParams = ();
	my $sql = my $sqlCmp = $virtualLibraries->{$thisVLCvirtualLibrary}->{'sql'};

	# included virtual libraries
	if ($virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('includedvlids = '.Data::Dump::dump($virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'}));
		my @includedVLIBrealIDs = ();
		foreach (split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'includedvlids'})) {
			my $VLrealID = Slim::Music::VirtualLibraries->getRealId($_);
			if ($VLrealID) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Will replace permanent virtual library ID '$_' with current real ID '$VLrealID'.");
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
		main::DEBUGLOG && $log->is_debug && $log->debug('excludedvlids = '.Data::Dump::dump($virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'}));
		my @excludedVLIBrealIDs = ();
		foreach (split(/,/, $virtualLibraries->{$thisVLCvirtualLibrary}->{'excludedvlids'})) {
			my $VLrealID = Slim::Music::VirtualLibraries->getRealId($_);
			if ($VLrealID) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Will replace permanent virtual library ID '$_' with current real ID '$VLrealID'.");
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
		main::DEBUGLOG && $log->is_debug && $log->debug('sql = '.Data::Dump::dump($sqlCmp));
		main::DEBUGLOG && $log->is_debug && $log->debug('sql with replaced params = '.Data::Dump::dump($sql));
	}
	return $sql;
}

sub dailyVLrefreshScheduler {
	my $recentlyCreatedVLIDs = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('Recently created VLs = '.Data::Dump::dump($recentlyCreatedVLIDs));

	if ($prefs->get('vlstempdisabled')) {
		main::INFOLOG && $log->is_info && $log->info('Scheduled refresh is disabled as long as VLC VLs are globally disabled/paused.');
		main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for scheduled VL refresh');
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
	main::DEBUGLOG && $log->is_debug && $log->debug('dailyRefreshVLIDs = '.Data::Dump::dump(\@dailyRefreshVLIDs));

	# schedule refresh if requested
	if (scalar @dailyRefreshVLIDs > 0) {
		main::DEBUGLOG && $log->is_debug && $log->debug('These enabled VLs request a daily refresh: '.Data::Dump::dump(\@dailyRefreshVLIDs));
		main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for scheduled VL refresh');
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
				# still scanning or no library, try again later
				if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
					main::INFOLOG && $log->is_info && $log->info('Cannot refresh eligible VLs now. No library or still scanning. Will try again after 5 mins.');
					Slim::Utils::Timers::setTimer(undef, time() + 300, \&dailyVLrefreshScheduler);
					return;
				}
				main::INFOLOG && $log->is_info && $log->info('Last refresh day was '.($lastRefreshDay ? 'on day '.$lastRefreshDay : 'never').'. Refreshing eligible VLs now.');
				my $started = time();

				foreach my $thisVLID (@dailyRefreshVLIDs) {
					if ($recentlyCreatedVLIDs && ref($recentlyCreatedVLIDs) eq 'HASH' && $recentlyCreatedVLIDs->{$thisVLID}) {
						main::INFOLOG && $log->is_info && $log->info("Skipping refresh for VL '$thisVLID because it has just been created.");
						next;
					}
					my $VLexists = Slim::Music::VirtualLibraries->getRealId($thisVLID);
					Slim::Music::VirtualLibraries->rebuild($VLexists) if $VLexists;
					main::INFOLOG && $log->is_info && $log->info("Refreshed VL '$thisVLID'.") if $VLexists;;
				}

				my $ended = time() - $started;
				main::INFOLOG && $log->is_info && $log->info('Scheduled refresh of selected virtual libraries completed after '.$ended.' seconds.');
				$prefs->set('lastscheduledrefresh_day', $mday);
				Slim::Utils::Timers::setTimer(undef, time() + 120, \&dailyVLrefreshScheduler);
			} else {
				my $timeleft = $dailyVLrefreshTime - $currentTime;
				if ($lastRefreshDay eq $mday) {
					$timeleft = $timeleft + 24 * 60 * 60;
				}
				main::INFOLOG && $log->is_info && $log->info(parse_duration($timeleft)." until next scheduled VL refresh at ".$dailyVLrefreshTimeUnparsed);
				Slim::Utils::Timers::setTimer(undef, time() + $timeleft, \&dailyVLrefreshScheduler);
			}
		} else {
			$log->warn('dailyVLrefreshTime = not defined or empty string');
		}

	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for scheduled VL refresh');
		Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
		main::INFOLOG && $log->is_info && $log->info('Found no enabled VLs requesting daily refresh.')
	}
}

sub getVLCvirtualLibraryList {
	my $client = shift;
	my @pluginDirs = ();

	my $itemConfiguration = getConfigManager()->readItemConfiguration($client, 1);
	$virtualLibraries = $itemConfiguration->{'virtuallibraries'};

	main::DEBUGLOG && $log->is_debug && $log->debug('virtual libraries = '.Data::Dump::dump($virtualLibraries));
}

sub getConfigManager {
	if (!defined($configManager)) {
		my %parameters = (
			'addSqlErrorCallback' => undef
		);
		$configManager = Plugins::VirtualLibraryCreator::ConfigManager::Main->new(\%parameters);
	}
	return $configManager;
}


sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub starts_with {
	# complete_string, start_string, position
	return rindex($_[0], $_[1], 0);
	# returns 0 for yes, -1 for no
}

sub commit {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->commit();
	}
}

sub rollback {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->rollback();
	}
}

1;
