#
# Virtual Library Creator
# (c) 2023 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::VirtualLibraryCreator::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use File::Basename qw(basename);
use File::Slurp qw(read_file);
use File::Spec::Functions qw(:ALL);
use HTML::Entities qw(encode_entities decode_entities);
use POSIX qw(floor);
use Time::HiRes qw(time);
use XML::Simple qw(XMLin);

my $prefs = preferences('plugin.virtuallibrarycreator');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.virtuallibrarycreator');

my $virtualLibraries;
my $templates; # cached template definitions, populated by _getTemplates on first use
my (%lineParamRegexes, %vlsWithoutTracks, %rebuildRetried);
*escape = \&URI::Escape::uri_escape_utf8;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(initVirtualLibraries dailyVLrefreshScheduler starts_with readItemConfiguration _getTemplates _decodeContent)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );


sub initVirtualLibraries {
	my ($importerCall, $recreateChangedVL) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Start initializing VLs.');
	my $started = time();

	## update list of available virtual library VLC definitions
	getVLCvirtualLibraryList();

	# if VL includes/excludes other VLC libraries, set library init order accordingly so VLs exist when needed
	setLibraryInitOrder();

	my %enabledVLIDs = map {$virtualLibraries->{$_}->{'VLID'} => 1} grep {$virtualLibraries->{$_}->{'enabled'}} keys %{$virtualLibraries};
	delete $vlsWithoutTracks{$_} foreach grep {!$enabledVLIDs{$_}} keys %vlsWithoutTracks;
	main::DEBUGLOG && $log->is_debug && $log->debug('virtual libraries = '.Data::Dump::dump($virtualLibraries));

	my $LMS_virtuallibraries = Slim::Music::VirtualLibraries->getLibraries();
	main::DEBUGLOG && $log->is_debug && $log->debug('Found these registered LMS virtual libraries: '.Data::Dump::dump($LMS_virtuallibraries));

	## unregister virtual libraries if globally disabled, post-scan call or manual refresh
	if ($prefs->get('vlstempdisabled') || $importerCall || $prefs->get('manualrefresh')) {
		my $VLunregCount = 0;
		# on a manual refresh players keep their library view if the VL is registered again below
		my $keepClientPref = ($prefs->get('manualrefresh') && !$prefs->get('vlstempdisabled')) ? 1 : 0;
		foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
			my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
			main::DEBUGLOG && $log->is_debug && $log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'PLUGIN_VLC_VLID_') == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID, ($keepClientPref && $enabledVLIDs{$thisVLID}) ? 1 : 0);
				$VLunregCount++;
			}
		}

		if ($prefs->get('vlstempdisabled')) {
			%vlsWithoutTracks = ();
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
		# VLs that include/exclude a (re)created VL are recreated as well
		my %recreateVLIDs = ();

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
			if (($recreateChangedVL && $recreateChangedVL eq $VLCitemID) || $recreateVLIDs{$VLID}) {
				main::INFOLOG && $log->is_info && $log->info("Request to (re)create VL '$VLID'");
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id}, 1);
			}

			my $VLalreadyexists = Slim::Music::VirtualLibraries->getRealId($VLID);
			main::DEBUGLOG && $log->is_debug && $log->debug('Check if VL already exists. Returned real library id = '.Data::Dump::dump($VLalreadyexists));
			if (defined $VLalreadyexists) {
				delete $vlsWithoutTracks{$VLID};
				main::DEBUGLOG && $log->is_debug && $log->debug("VL '$VLID' already exists.");
				next;
			}

			main::DEBUGLOG && $log->is_debug && $log->debug("VL '$VLID' has not been created yet. Creating & registering it now.");
			eval {
				Slim::Music::VirtualLibraries->registerLibrary($library);
				Slim::Music::VirtualLibraries->rebuild($library->{id});
			};
			if ($@) {
				my $error = $@;
				# LMS leaves its progress handler installed if a rebuild fails
				eval { Slim::Schema->dbh->sqlite_progress_handler(0, undef) };
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
				if ($error =~ /locked/i && !$importerCall && !$rebuildRetried{$VLID}) {
					# another task used the database at the same time. Try again later
					$rebuildRetried{$VLID} = 1;
					main::INFOLOG && $log->is_info && $log->info("Could not build library '".$library->{'name'}."' because the database was busy. Will try again later.");
					scheduleVLrecreate($VLCitemID);
				} else {
					delete $rebuildRetried{$VLID};
					$log->error("Error registering library '".$library->{'name'}."'. Is SQLite statement valid? Error message: $error");
				}
				next;
			}
			delete $rebuildRetried{$VLID};
			$recentlyCreatedVLIDs{$VLID} = 1;
			$recreateVLIDs{$_} = 1 foreach getVLIDsWithDependents($VLID);

			my $trackCount = Slim::Music::VirtualLibraries->getTrackCount($VLID) || 0;
			main::DEBUGLOG && $log->is_debug && $log->debug("track count vlib '$browsemenu_name' = ".Data::Dump::dump($trackCount));
			if ($trackCount == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
				$vlsWithoutTracks{$VLID} = 1;
				main::INFOLOG && $log->is_info && $log->info("Unregistering vlib '$browsemenu_name' because it has 0 tracks.");
			} else {
				delete $vlsWithoutTracks{$VLID};
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

sub setLibraryInitOrder {
	# VLs that include/exclude other VLC libraries must be created after them
	foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
		$virtualLibraries->{$thisVLCvirtualLibrary}->{'libraryinitorder'} = 50;
	}
	my %itemKeyByVLID = map {$virtualLibraries->{$_}->{'VLID'} => $_} keys %{$virtualLibraries};
	# a VL can depend on a VL that depends on another one. Repeat until the order is stable (n passes suffice unless VLs reference each other in a circle)
	for (1 .. scalar(keys %{$virtualLibraries})) {
		my $orderChanged = 0;
		foreach my $thisVLCvirtualLibrary (keys %{$virtualLibraries}) {
			my $thisVL = $virtualLibraries->{$thisVLCvirtualLibrary};
			next unless $thisVL->{'includedvlids'} || $thisVL->{'excludedvlids'};
			my $thisLibraryInitOrder = 600;
			foreach my $baseVLID (split(/,/, ($thisVL->{'includedvlids'} || '').','.($thisVL->{'excludedvlids'} || ''))) {
				next unless $itemKeyByVLID{$baseVLID} && starts_with($baseVLID, 'PLUGIN_VLC_VLID_') == 0;
				my $baseVLinitOrder = $virtualLibraries->{$itemKeyByVLID{$baseVLID}}->{'libraryinitorder'};
				$thisLibraryInitOrder = $baseVLinitOrder + 10 if $thisLibraryInitOrder <= $baseVLinitOrder;
			}
			if ($thisVL->{'libraryinitorder'} != $thisLibraryInitOrder) {
				$thisVL->{'libraryinitorder'} = $thisLibraryInitOrder;
				$orderChanged = 1;
			}
		}
		last unless $orderChanged;
	}
}

sub getVLIDsWithDependents {
	# returns the given VLIDs plus the enabled VLs that include/exclude them (directly or indirectly), sorted by library init order
	my %result = map {$_ => 1} @_;
	my $added = 1;
	while ($added) {
		$added = 0;
		foreach my $thisVL (values %{$virtualLibraries}) {
			next if $result{$thisVL->{'VLID'}} || !$thisVL->{'enabled'};
			foreach my $baseVLID (split(/,/, ($thisVL->{'includedvlids'} || '').','.($thisVL->{'excludedvlids'} || ''))) {
				next unless $result{$baseVLID};
				$result{$thisVL->{'VLID'}} = 1;
				$added = 1;
				last;
			}
		}
	}
	my %initOrderByVLID = map {$_->{'VLID'} => ($_->{'libraryinitorder'} || 0)} values %{$virtualLibraries};
	return sort {($initOrderByVLID{$a} || 0) <=> ($initOrderByVLID{$b} || 0) || $a cmp $b} keys %result;
}

sub vlHasNoTracks {
	my $VLID = shift;
	return $vlsWithoutTracks{$VLID} ? 1 : 0;
}

sub rebuildVL {
	my $libraryID = shift;
	return 1 if eval { Slim::Music::VirtualLibraries->rebuild($libraryID); 1 };
	# LMS leaves its progress handler installed if a rebuild fails
	eval { Slim::Schema->dbh->sqlite_progress_handler(0, undef) };
	return 0;
}

sub scheduleVLrecreate {
	my $VLCitemID = shift;
	Slim::Utils::Timers::killTimers($VLCitemID, \&Plugins::VirtualLibraryCreator::Plugin::initVirtualLibrariesDelayed);
	Slim::Utils::Timers::setTimer($VLCitemID, time() + 30, \&Plugins::VirtualLibraryCreator::Plugin::initVirtualLibrariesDelayed);
}

sub logMissingBaseVL {
	my ($baseVLID, $parameterName, $VLname) = @_;
	# an enabled VLC library is only missing if it has no tracks or could not be built
	if (grep {$_->{'VLID'} eq $baseVLID && $_->{'enabled'}} values %{$virtualLibraries}) {
		main::INFOLOG && $log->is_info && $log->info("The virtual library '".$baseVLID."' of your parameter '".$parameterName."' in your virtual library '".$VLname."' is currently not registered (no tracks). It is treated as empty.");
	} else {
		$log->error("The virtual library '".$baseVLID."' of your parameter '".$parameterName."' in your virtual library '".$VLname."' does not exist. Your virtual library definition will not work (correctly).");
	}
}

sub replaceParametersInSQL {
	my $thisVLCvirtualLibrary = shift;
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
				logMissingBaseVL($_, 'included virtual libraries', $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'});
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
				logMissingBaseVL($_, 'excluded virtual libraries', $virtualLibraries->{$thisVLCvirtualLibrary}->{'name'});
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
			$lastRefreshDay = '' unless defined($lastRefreshDay);
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

				# VLs that include/exclude a refreshed VL are refreshed after it
				my %itemIDbyVLID = map {$_->{'VLID'} => $_->{'id'}} values %{$virtualLibraries};
				my $VLsWithoutTracks = 0;
				foreach my $thisVLID (getVLIDsWithDependents(@dailyRefreshVLIDs)) {
					if ($recentlyCreatedVLIDs && ref($recentlyCreatedVLIDs) eq 'HASH' && $recentlyCreatedVLIDs->{$thisVLID}) {
						main::INFOLOG && $log->is_info && $log->info("Skipping refresh for VL '$thisVLID' because it has just been created.");
						next;
					}
					my $VLexists = Slim::Music::VirtualLibraries->getRealId($thisVLID);
					if (!$VLexists) {
						$VLsWithoutTracks++ if $vlsWithoutTracks{$thisVLID};
						next;
					}
					if (!rebuildVL($VLexists)) {
						main::INFOLOG && $log->is_info && $log->info("Could not refresh VL '$thisVLID' because the database was busy. Will try again later.");
						scheduleVLrecreate($itemIDbyVLID{$thisVLID}) if $itemIDbyVLID{$thisVLID};
						next;
					}
					main::INFOLOG && $log->is_info && $log->info("Refreshed VL '$thisVLID'.");
					if (!Slim::Music::VirtualLibraries->getTrackCount($VLexists)) {
						Slim::Music::VirtualLibraries->unregisterLibrary($VLexists);
						$vlsWithoutTracks{$thisVLID} = 1;
						$VLsWithoutTracks++;
						main::INFOLOG && $log->is_info && $log->info("Unregistering vlib '$thisVLID' because it has 0 tracks.");
					}
				}

				my $ended = time() - $started;
				main::INFOLOG && $log->is_info && $log->info('Scheduled refresh of selected virtual libraries completed after '.$ended.' seconds.');
				$prefs->set('lastscheduledrefresh_day', $mday);
				# VLs without tracks may have tracks now. Init creates them again
				Slim::Utils::Timers::setTimer(undef, time() + 10, \&Plugins::VirtualLibraryCreator::Plugin::initVirtualLibrariesDelayed) if $VLsWithoutTracks;
				Slim::Utils::Timers::setTimer(undef, time() + 120, \&dailyVLrefreshScheduler);
			} else {
				my $timeleft = $dailyVLrefreshTime - $currentTime;
				$timeleft += 24 * 60 * 60 if $lastRefreshDay eq $mday;
				main::INFOLOG && $log->is_info && $log->info(parse_duration($timeleft)." until next scheduled VL refresh at ".$dailyVLrefreshTimeUnparsed);
				Slim::Utils::Timers::setTimer(undef, time() + $timeleft, \&dailyVLrefreshScheduler);
			}
		} else {
			$log->warn('dailyVLrefreshTime = not defined or empty string');
		}

	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for scheduled VL refresh');
		Slim::Utils::Timers::killOneTimer(undef, \&dailyVLrefreshScheduler);
		main::INFOLOG && $log->is_info && $log->info('Found no enabled VLs requesting daily refresh.');
	}
}

sub getVLCvirtualLibraryList {
	my $client = shift;
	my $itemConfiguration = readItemConfiguration($client);
	$virtualLibraries = $itemConfiguration->{'virtuallibraries'};
	main::DEBUGLOG && $log->is_debug && $log->debug('virtual libraries = '.Data::Dump::dump($virtualLibraries));
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



### templates (read-only)

sub readTemplateConfiguration {
	my %result = ();
	for my $pluginDir (Slim::Utils::OSDetect::dirsFor('Plugins')) {
		my $templateDir = catdir($pluginDir, 'VirtualLibraryCreator', 'Templates');
		main::DEBUGLOG && $log->is_debug && $log->debug('Checking for dir: '.$templateDir);
		next unless -d $templateDir;
		_readConfigFiles($templateDir, 'sql.xml', 1, sub {
			my ($item, $content) = @_;
			eval { _parseTemplate($item, $content, \%result) };
			return $@;
		});
	}
	return \%result;
}

sub _getTemplates {
	$templates = readTemplateConfiguration() unless defined($templates);
	return $templates;
}



### virtual library item configuration (rebuilt on every list.html view)

sub readItemConfiguration {
	my $client = shift;

	my $dir = $prefs->get('customvirtuallibrariesfolder');
	main::DEBUGLOG && $log->is_debug && $log->debug("Searching for item configuration in: $dir");

	_getTemplates();
	my %customItems = ();
	my %virtualLibrariesResult = ();

	if (!defined $dir || !-d $dir) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Skipping custom configuration scan - directory is undefined');
	} else {
		# parse .sql files (full VL metadata: enabled, browse menus, daily refresh, etc.)
		_readConfigFiles($dir, 'sql', 0, sub {
			my ($item, $content) = @_;
			return _parseContent($item, $content, \%customItems);
		});
		# snapshot of full .sql-derived metadata BEFORE the customvalues.xml pass below can overwrite entries. LMS registration (initVirtualLibraries) uses this.
		%virtualLibrariesResult = %customItems;

		# parse .customvalues.xml files (template-based VLs); replaces matching entries with a display-oriented name/id
		_readConfigFiles($dir, 'customvalues.xml', 0, sub {
			my ($item, $content) = @_;
			return _parseTemplateContent($item, $content, \%customItems);
		});
	}

	my %localItems = ();
	for my $itemId (keys %customItems) {
		my $item = { %{$virtualLibrariesResult{$itemId} || {}}, %{$customItems{$itemId}} };
		$localItems{$item->{'id'}} = $item;
	}

	for my $key (keys %localItems) {
		$localItems{$key}{'name'} =~ s/\'\'/\'/g if defined($localItems{$key}{'name'});
	}

	return {'virtuallibraries' => \%virtualLibrariesResult, 'webvirtuallibraries' => \%localItems};
}



### file reading helpers

sub _readConfigFiles {
	my ($dir, $extension, $keepExtension, $parseCallback) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("Loading configuration from: $dir");
	for my $path (Slim::Utils::Misc::readDirectory($dir, $extension, 'dorecursive')) {
		next unless $path =~ /\.\Q$extension\E$/;
		next if -d $path;

		my $item = basename($path);
		$item =~ s/\.\Q$extension\E$// unless $keepExtension;

		my $content = eval { read_file($path) };
		$content = _decodeContent($content, $item) if $content;

		if ($content) {
			my $errorMsg = $parseCallback->($item, $content);
			$log->error("Unable to parse file: $path\n$errorMsg") if $errorMsg;
		} else {
			$log->error("Unable to open file: $path".($@ ? "\nBecause of: $@" : ''));
		}
	}
}

sub _decodeContent {
	my ($content, $name) = @_;
	my $encoding = Slim::Utils::Unicode::encodingFromString($content);
	if ($encoding ne 'utf8') {
		main::DEBUGLOG && $log->is_debug && $log->debug("Loading $name and converting from $encoding to utf8");
		$content = Slim::Utils::Unicode::latin1toUTF8($content);
		return Slim::Utils::Unicode::utf8on($content);
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("Loading $name without conversion with encoding ".$encoding);
	return Slim::Utils::Unicode::utf8decode($content, 'utf8');
}



### parsers

sub _parseTemplate {
	my ($item, $content, $result) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('XMLin part');
	my $xml = eval { XMLin($content, forcearray => ['item'], keyattr => []) };
	if ($@) {
		$log->warn("Failed to parse configuration ($item) because: $@");
		return;
	}
	my $include = 1;
	if (defined($xml->{'requireplugins'})) {
		$include = Slim::Utils::PluginManager->isEnabled('Plugins::'.$xml->{'requireplugins'}) ? 1 : 0;
	}
	return unless $include && defined($xml->{'template'});
	$xml->{'template'}{'id'} = escape($item);
	$result->{$item} = $xml->{'template'};
}

sub _parseContent {
	my ($item, $content, $result) = @_;

	decode_entities($content);
	my @lines = split(/[\n\r]+/, $content);
	my ($name, $statement, $fulltext) = (undef, '', '');
	my ($isEnabled, $dailyVLrefresh, $libraryInitOrder) = (0, 0, 0);
	my $external = _externalCheck($item);
	my ($browseMenusArtists, $browseMenusAlbums, $browseMenusMisc) = ('', '', '');
	my ($browseMenusArtistsHomeMenu, $browseMenusAlbumsHomeMenu, $browseMenusMiscHomeMenu);
	my ($browseMenusArtistsHomeMenuWeight, $browseMenusAlbumsHomeMenuWeight, $browseMenusMiscHomeMenuWeight) = (0, 0, 0);
	my ($includedVLids, $excludedVLids) = ('', '');

	for my $line (@lines) {
		$line .= "\n";
		$fulltext .= $line if $external && $line !~ /^--/ && $line !~ /^\s*$/;
		chomp $line;

		if (my $val = _parseLineParam($line, 'VirtualLibraryName')) { $name = $val }
		if (_parseLineParam($line, 'VirtualLibraryEnabled')) { $isEnabled = 1 }
		if (_parseLineParam($line, 'VirtualLibraryDailyVLrefresh')) { $dailyVLrefresh = 1 }
		if (my $val = _parseLineParam($line, 'VirtualLibraryInitOrder')) { $libraryInitOrder = $val }
		if (my $val = _parseLineParam($line, 'VirtualLibraryBrowseMenusArtists')) { $browseMenusArtists = $val }
		if (_parseLineParam($line, 'VirtualLibraryBrowseMenusArtistsHomeMenu')) { $browseMenusArtistsHomeMenu = 1 }
		if (my $val = _parseLineParam($line, 'VirtualLibraryBrowseMenusArtistsHomeMenuWeight')){ $browseMenusArtistsHomeMenuWeight = $val }
		if (my $val = _parseLineParam($line, 'VirtualLibraryBrowseMenusAlbums')) { $browseMenusAlbums = $val }
		if (_parseLineParam($line, 'VirtualLibraryBrowseMenusAlbumsHomeMenu')) { $browseMenusAlbumsHomeMenu = 1 }
		if (my $val = _parseLineParam($line, 'VirtualLibraryBrowseMenusAlbumsHomeMenuWeight')) { $browseMenusAlbumsHomeMenuWeight = $val }
		if (my $val = _parseLineParam($line, 'VirtualLibraryBrowseMenusMisc')) { $browseMenusMisc = $val }
		if (_parseLineParam($line, 'VirtualLibraryBrowseMenusMiscHomeMenu')) { $browseMenusMiscHomeMenu = 1 }
		if (my $val = _parseLineParam($line, 'VirtualLibraryBrowseMenusMiscHomeMenuWeight')) { $browseMenusMiscHomeMenuWeight = $val }
		if (my $val = _parseLineParam($line, 'VirtualLibraryIncludedVLs')) { $includedVLids = $val }
		if (my $val = _parseLineParam($line, 'VirtualLibraryExcludedVLs')) { $excludedVLids = $val }

		# strip comments, but a '--' inside a quoted string is not a comment
		$line =~ s/^((?:[^'"-]++|-(?!-)|'(?:[^']|'')*+'|"(?:[^"]|"")*+")*+)\s*--.*$/$1/;
		$line =~ s/^\s*//o;
		next if $line =~ /^--/ || $line =~ /^\s*$/;
		$line =~ s/\s+$//;
		$statement .= ($statement =~ /;$/ ? "\n" : $statement ? " " : '').$line;
	}

	$name = $item unless $name;
	return "No name or SQL statement found" unless $name && $statement;

	my %vl = (
		'id' => $item, 'file' => $item,
		'name' => $name,
		'VLID' => 'PLUGIN_VLC_VLID_'.trim_all(uc($item)),
		'external' => $external ? 1 : 0,
		'sql' => Slim::Utils::Unicode::utf8decode($statement, 'utf8'),
		'fulltext' => $external ? Slim::Utils::Unicode::utf8decode($fulltext, 'utf8') : '',
	);
	$vl{'enabled'} = 1 if $isEnabled;
	$vl{'dailyvlrefresh'} = 1 if $dailyVLrefresh;
	$vl{'libraryinitorder'} = $libraryInitOrder if $libraryInitOrder;
	$vl{'artistmenus'} = $browseMenusArtists if $browseMenusArtists ne '';
	$vl{'artistmenushomemenu'} = 1 if $browseMenusArtistsHomeMenu;
	$vl{'artistmenushomemenuweight'} = $browseMenusArtistsHomeMenuWeight if $browseMenusArtistsHomeMenuWeight;
	$vl{'albummenus'} = $browseMenusAlbums if $browseMenusAlbums ne '';
	$vl{'albummenushomemenu'} = 1 if $browseMenusAlbumsHomeMenu;
	$vl{'albummenushomemenuweight'} = $browseMenusAlbumsHomeMenuWeight if $browseMenusAlbumsHomeMenuWeight;
	$vl{'miscmenus'} = $browseMenusMisc if $browseMenusMisc ne '';
	$vl{'miscmenushomemenu'} = 1 if $browseMenusMiscHomeMenu;
	$vl{'miscmenushomemenuweight'} = $browseMenusMiscHomeMenuWeight if $browseMenusMiscHomeMenuWeight;
	$vl{'hasbrowsemenus'} = 1 if $browseMenusArtists ne '' || $browseMenusAlbums ne '' || $browseMenusMisc ne '';
	$vl{'includedvlids'} = $includedVLids if $includedVLids ne '';
	$vl{'excludedvlids'} = $excludedVLids if $excludedVLids ne '';
	$result->{$item} = \%vl;
	return;
}

sub _parseLineParam {
	my ($line, $key) = @_;
	my $regexes = $lineParamRegexes{$key} ||= [qr/^\s*--\s*\Q$key\E\s*[:=]\s*/, qr/^\s*--\s*\Q$key\E\s*[:=]\s*(.+?)\s*$/];
	return unless $line =~ $regexes->[0];
	$line =~ $regexes->[1];
	my $val = $1;
	if ($val) {
		return $val;
	}
	$log->warn("Error in parameter: $line");
	return;
}

sub _externalCheck {
	my $filename = shift;
	my $dir = $prefs->get('customvirtuallibrariesfolder');
	return -f catfile($dir, "${filename}.customvalues.xml") ? undef : 1;
}

sub _parseTemplateContent {
	my ($item, $content, $result) = @_;

	my $valuesXml = eval { XMLin($content, forcearray => ['parameter', 'value'], keyattr => []) };
	if ($@) {
		$log->warn("Failed to parse virtuallibrary configuration ($item) because: $@");
		return "$@";
	}

	my $templateId = lc($valuesXml->{'template'}{'id'});
	my $template = $templates->{$templateId};
	if (!defined($template)) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Template $templateId not found");
		return;
	}

	my %templateParameters = ();
	for my $p (@{$valuesXml->{'template'}{'parameter'}}) {
		my $values = $p->{'value'};
		$values = [$p->{'content'}] if !defined($values) && defined($p->{'content'});
		my $value = '';
		for my $v (@{$values || []}) {
			next if ref($v) eq 'HASH';
			$value .= ',' if $value ne '';
			$v =~ s/\'/\'\'/g if (!defined($p->{'rawvalue'}) || !$p->{'rawvalue'}) && $p->{'id'} ne 'virtuallibraryname';
			$value .= $p->{'quotevalue'} ? "'".encode_entities($v, '&<>')."'" : encode_entities($v, '&<>');
		}
		$templateParameters{$p->{'id'}} = $value;
	}

	my $localcontext = {};
	if (defined($template->{'parameter'})) {
		my $tparams = $template->{'parameter'};
		$tparams = [$tparams] if ref($tparams) ne 'ARRAY';
		for my $p (@{$tparams}) {
			next unless defined($p->{'type'}) && defined($p->{'id'}) && defined($p->{'name'});
			if (!defined($templateParameters{$p->{'id'}})) {
				my $value = $p->{'value'};
				$value = !defined($value) || ref($value) eq 'HASH' ? (defined($p->{'content'}) ? [$p->{'content'}] : '') : $value;
				$templateParameters{$p->{'id'}} = $value;
			}
			$templateParameters{$p->{'id'}} = undef if defined($p->{'requireplugins'}) && !Slim::Utils::PluginManager->isEnabled('Plugins::'.$p->{'requireplugins'});
			if (defined($p->{'minlmsversion'}) && Slim::Utils::Versions->compareVersions($::VERSION, $p->{'minlmsversion'}) == -1) {
				main::DEBUGLOG && $log->is_debug && $log->debug('LMS version = '.$::VERSION.' -- min. LMS version for param "'.$p->{'id'}.'" = '.$p->{'minlmsversion'});
				$templateParameters{$p->{'id'}} = undef;
			}
			if (defined($templateParameters{$p->{'id'}}) && Slim::Utils::Unicode::encodingFromString($templateParameters{$p->{'id'}}) ne 'utf8') {
				$templateParameters{$p->{'id'}} = Slim::Utils::Unicode::latin1toUTF8($templateParameters{$p->{'id'}});
			}
		}
		$localcontext->{'virtuallibraryname'} = $templateParameters{'virtuallibraryname'};
	}

	$result->{$item} = {
		'id' => $item, 'file' => $item,
		'name' => $localcontext->{'virtuallibraryname'},
		'VLID' => 'PLUGIN_VLC_VLID_'.trim_all(uc($item)),
	};
	return;
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}

1;
