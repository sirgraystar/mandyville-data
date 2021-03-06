package Mandyville::Players;

use Mojo::Base -base, -signatures;

use Mandyville::API::Understat;
use Mandyville::API::FootballData;
use Mandyville::Competitions;
use Mandyville::Countries;
use Mandyville::Database;
use Mandyville::Fixtures;
use Mandyville::Gameweeks;
use Mandyville::Utils qw(current_season debug);

use Const::Fast;
use Carp;
use List::Util qw(any);
use SQL::Abstract::More;

const my $UNDERSTAT_MAPPINGS => {
    npxG      => 'npxg',
    xA        => 'xa',
    xG        => 'xg',
    xGBuildup => 'xg_buildup',
    xGChain   => 'xg_chain',
};

=head1 NAME

  Mandyville::Players - fetch and store player data

=head1 SYNOPSIS

  use Mandyville::Players;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $teams = Mandyville::Teams->new({
      dbh  => $dbh,
      sqla => $sqla,
  });

  my $comps = Mandyville::Competitions->new({});

  my $fixtures = Mandyville::Fixtures->new({
      comps => $comps,
      dbh   => $dbh,
      sqla  => $sqla,
      teams => $teams,
  });

  my $players = Mandyville::Players->new({
      fapi      => Mandyville::API::FootballData->new,
      uapi      => Mandyville::API::Understat->new,
      comps     => $comps,
      countries => Mandyville::Countries->new,
      fixtures  => $fixtures,
      gameweeks => Mandyville::Gameweeks->new,
      dbh       => $dbh,
      sqla      => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing player data,
  including player fixture data. It currently uses the football-data
  API for this, but will eventually use the understat data and the FPL
  API as well.

=head1 METHODS

=over

=item fapi

  An instance of Mandyville::API::FootballData

=item uapi

  An instance of Mandyville::API::Understat

=item comps

  An instance of Mandyville::Competitions.

=item countries

  An instance of Mandyville::Countries.

=item dbh

  A read-write handle to the Mandyville database.

=item fixtures

  An instance of Mandyville::Fixtures.

=item sqla

  An instance of SQL::Abstract::More.

=item teams

  An instance of Mandyville::Teams.

=cut

has 'fapi'      => sub { shift->{fapi} };
has 'uapi'      => sub { shift->{uapi} };
has 'comps'     => sub { shift->{comps} };
has 'countries' => sub { shift->{countries} };
has 'dbh'       => sub { shift->{dbh} };
has 'fixtures'  => sub { shift->{fixtures} };
has 'gameweeks' => sub { shift->{gameweeks} };
has 'sqla'      => sub { shift->{sqla} };
has 'teams'     => sub { shift->{teams} };

=item new ([ OPTIONS ])

  Creates a new instance of the module, and sets the various required
  attributes. C<OPTIONS> is a hashref that can contain the following
  fields:

    * dbh  => A read-write handle to the Mandyville database
    * sqla => An instance of SQL::Abstract::More

  If these options aren't passed in, they will be instantied by this
  method. However, it's recommended to pass these options in for
  performance and memory usage reasons.

=cut

sub new($class, $options) {
    $options->{fapi} //= Mandyville::API::FootballData->new;
    $options->{uapi} //= Mandyville::API::Understat->new;
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    $options->{countries} //= Mandyville::Countries->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{comps} //= Mandyville::Competitions->new({
        fapi      => $options->{fapi},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        sqla      => $options->{sqla},
    });

    $options->{gameweeks} //= Mandyville::Gameweeks->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{teams} //= Mandyville::Teams->new({
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    });

    $options->{fixtures} //=Mandyville::Fixtures->new({
        comps => $options->{comps},
        dbh   => $options->{dbh},
        sqla  => $options->{sqla},
        teams => $options->{teams},
    });

    my $self = {
        fapi      => $options->{fapi},
        uapi      => $options->{uapi},
        comps     => $options->{comps},
        countries => $options->{countries},
        dbh       => $options->{dbh},
        fixtures  => $options->{fixtures},
        gameweeks => $options->{gameweeks},
        sqla      => $options->{sqla},
        teams     => $options->{teams},
    };

    bless $self, $class;
    return $self;
}

=item add_fpl_season_info ( PLAYER_ID, SEASON, FPL_ID, POSITION_ID )

  Add the FPL season info for the given C<PLAYER_ID>. Checks for the
  season info before inserting. Returns the ID of the season info
  entry.

  C<FPL_ID> is the current season FPL ID, not the FPL "code".
  C<POSITION_ID> is the entity type ID of the player (a number between
  1 and 4).

=cut

sub add_fpl_season_info($self, $player_id, $season, $fpl_id, $position_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'fpl_season_info',
        -where   => {
            player_id => $player_id,
            season    => $season,
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_positions',
            -where   => {
                element_type_id => $position_id,
            },
        );

        my ($fpl_position_id) =
            $self->dbh->selectrow_array($stmt, undef, @bind);

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'fpl_season_info',
            -values    => {
                player_id        => $player_id,
                season           => $season,
                fpl_season_id    => $fpl_id,
                fpl_positions_id => $fpl_position_id,
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return $id;
}

=item find_player_by_fpl_info ( FPL_INFO )

  Attempt to find a player in the mandyville database based on their
  info in the FPL API. Takes the following steps:

  * Check first name and last name for exact matches
  * Check 'web name' (usually surname but sometimes common name) for an
    exact match with surname and a match (partial or exact) with first
    name)
  * Check split of 'web name' against first name and last name

  Only matches on players that played a Premier League game at some
  point in the database (not limited to the current season).

=cut

sub find_player_by_fpl_info($self, $fpl_info) {
    my $combined_name = $fpl_info->{first_name} . ' ' .
                        $fpl_info->{second_name};

    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(p.id p.first_name p.last_name)],
        -from    => [-join => qw(
            players|p <=>{p.id=f.player_id} fpl_names|f
        )],
        -where   => {
            'f.name' => $combined_name,
        }
    );

    my ($result) = $self->dbh->selectrow_hashref($stmt, { Slice => {} }, @bind);

    return $result if defined $result;

    my %query = (
        -columns  => [qw(p.id p.first_name p.last_name)],
        -from     => [-join => qw(
            players|p <=>{p.id=pf.player_id}     players_fixtures|pf
                      <=>{pf.fixture_id=f.id}    fixtures|f
                      <=>{f.competition_id=c.id} competitions|c
                      <=>{c.country_id=co.id}    countries|co
        )],
        -where    => {
            'c.name'       => 'Premier League',
            'co.name'      => 'England',
            'p.first_name' => $fpl_info->{first_name},
            'p.last_name'  => $fpl_info->{second_name},
        },
        -group_by => 'p.id',
    );

    ($stmt, @bind) = $self->sqla->select(%query);

    my $matches =
        $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    if (scalar @$matches == 1) {
        return $matches->[0];
    } elsif (scalar @$matches > 1) {
        die 'Multiple matches, bailing out';
    }

    my ($first_first_name) = $fpl_info->{first_name} =~ /^(\w+)\s/;

    $query{'-where'}->{'p.last_name'}  = $fpl_info->{web_name};
    $query{'-where'}->{'p.first_name'} = $first_first_name;

    ($stmt, @bind) = $self->sqla->select(%query);

    $matches = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    if (scalar @$matches == 1) {
        return $matches->[0];
    } elsif (scalar @$matches > 1) {
        die 'Multiple matches, bailing out';
    }

    if ($fpl_info->{web_name} =~ /\s/) {
        my ($first, $last) = $fpl_info->{web_name} =~ /(\w+)\s+(.+)$/;

        $query{'-where'}->{'p.first_name'} = $first;
        $query{'-where'}->{'p.last_name'}  = $last;

        ($stmt, @bind) = $self->sqla->select(%query);

        $matches =
            $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

        if (scalar @$matches == 1) {
            return $matches->[0];
        } elsif (scalar @$matches > 1) {
            die 'Multiple matches, bailing out';
        } else {
            die 'No match found';
        }
    } else {
        die 'No match found';
    }
}

=item find_understat_id ( ID )

  Attempt to find the understat ID for the player with the given
  C<ID>. C<ID> refers to the mandyville database ID in this case. Runs
  through the following steps to attempt to do this:

  * Work out the most teams for the player
  * Search understat for the player's full name
  * If there's a result with the correct team, use that ID
  * If not, search for the player's last name
  * If still not, search for the player's first name

  Note that understat team names won't always match mandyville database
  team names, and are usually shorter, so do a substring check when
  comparing team names.

  Inserts the understat ID into the database if one is found. Dies if
  no ID is found (since we want to alert and fix in that case).

=cut

sub find_understat_id($self, $id) {
    my $teams = $self->_get_teams($id);

    my ($first, $last) = $self->_get_name($id);

    my $full = "$first $last";

    my @options;
    if ($last ne '') {
        @options = ($full, $last, $first);
    } else {
        @options = ($first);
    }

    foreach my $string (@options) {
        my $res = $self->_search_understat_and_store(
            $string, $id, $teams
        );

        return $res if defined $res;
    }

    die "Couldn't find understat ID for player #$id: $full";
}

=item get_by_football_data_id ( FOOTBALL_DATA_ID )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. Does
  no insertion into the database; returns undef if no player is found,
  returns the mandyville database ID of the found player if a player is
  found.

=cut

sub get_by_football_data_id($self, $football_data_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'players',
        -where   => {
            football_data_id => $football_data_id,
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $id;
}

=item get_or_insert ( FOOTBALL_DATA_ID, PLAYER_INFO )

  Fetch the player associated with the given C<FOOTBALL_DATA_ID>. If no
  such player is found, insert the player into the database using the
  fields provided in C<PLAYER_INFO>. The C<first_name>, C<last_name>
  and C<country_name> attributes are required for insertion. The
  C<country_name> field should refer to the player's nationality, not
  their country of birth. Returns a hashref of the fetched or inserted
  player information.

=cut

sub get_or_insert($self, $football_data_id, $player_info) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(p.id p.first_name p.last_name c.name) ],
        -from    => [ -join => qw(
            players|p <=>{p.country_id=c.id} countries|c
        )],
        -where   => {
            'p.football_data_id' => $football_data_id,
        }
    );

    my ($id, $first_name, $last_name, $country_name) =
        $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        for (qw(first_name last_name country_name)) {
            croak "missing $_ attribute in player_info param"
                unless defined $player_info->{$_};
        }

        my $country_id =
            $self->countries->get_country_id($player_info->{country_name});

        if (!defined $country_id) {
            $country_id = $self->countries->get_id_for_alternate_name(
                $player_info->{country_name}
            );
        }

        die 'No country with name ' . $player_info->{country_name} . ' found'
            unless defined $country_id;

        ($stmt, @bind) = $self->sqla->insert(
            -into      => 'players',
            -values    => {
                first_name       => $player_info->{first_name},
                last_name        => $player_info->{last_name},
                country_id       => $country_id,
                football_data_id => $football_data_id,
            },
            -returning => 'id',
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        $first_name   = $player_info->{first_name};
        $last_name    = $player_info->{last_name};
        $country_name = $player_info->{country_name};
    }

    return {
        id           => $id,
        first_name   => $first_name,
        last_name    => $last_name,
        country_name => $country_name,
    };
}

=item get_team_for_player_fixture ( PLAYER_ID, FIXTURE_ID )

  Fetch the team ID for the given C<PLAYER_ID> and C<FIXTURE_ID>
  from the C<players_fixtures> DB table.

=cut

sub get_team_for_player_fixture($self, $player_id, $fixture_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'team_id',
        -from    => 'players_fixtures',
        -where   => {
            fixture_id => $fixture_id,
            player_id  => $player_id,
        }
    );

    my ($team_id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return $team_id;
}

=item get_with_missing_understat_ids ( COMP_IDS )

  Fetch all player IDs from the database without corresponding
  understat IDs. Returns an arrayref of these IDs.

  If C<COMP_IDS> is provided, only returns players who have known
  fixtures in the competitions corresponding to the provided IDs
  (regardless of whether they are currently playing in that
  competition, or if their most recent fixture is in another
  competiton).

=cut

sub get_with_missing_understat_ids($self, $comp_ids=[]) {
    my %query = (
        -columns => 'id',
        -from    => 'players',
        -where   => {
            understat_id => undef,
        }
    );

    if (scalar @$comp_ids > 0) {
        %query = (
            -columns => [-distinct => 'p.id'],
            -from    => [ -join => qw(
                players|p <=>{p.id=pf.player_id} players_fixtures|pf
                          <=>{pf.fixture_id=f.id} fixtures|f
            )],
            -where   => {
                'f.competition_id' => {
                    -in => $comp_ids,
                },
                'p.understat_id' => undef,
            }
        );
    }

    my ($stmt, @bind) = $self->sqla->select(%query);

    my $ids = $self->dbh->selectcol_arrayref($stmt, undef, @bind);
    return $ids;
}

=item get_without_understat_data ( SEASON, COMP_IDS )

  Fetches all players that have an understat ID but have no understat
  data. Excludes any non-unique understat IDs, since we don't want to
  mistakenly assign data to the wrong player. Only fetches for the
  given C<SEASON> and C<COMP_IDS> (which should be an arrayref of
  competition IDs).

  Returns an arrayref of hashrefs, containing the C<id> and
  C<understat_id> attributes.

=cut

sub get_without_understat_data($self, $season, $comp_ids) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'understat_id',
        -from    => 'players',
        -group_by => 'understat_id',
        -having   => {
            'COUNT(understat_id)' => { '>' => 1 }
        }
    );

    my $ids = $self->dbh->selectcol_arrayref($stmt, undef, @bind);

    my $where = {
        'f.competition_id' => { -in => $comp_ids },
        'f.season'         => $season,
        'p.understat_id'   => { '!=' => undef },
        'pf.goals'         => undef,
    };

    if (scalar @$ids > 0) {
        $where = $self->sqla->merge_conditions($where, {
            'p.understat_id' => { -not_in => $ids }
        });
    }

    ($stmt, @bind) = $self->sqla->select(
        -columns  => [-distinct => qw/p.id p.understat_id/],
        -from     => [ -join => qw(
            players|p <=>{p.id=pf.player_id}  players_fixtures|pf
                      <=>{pf.fixture_id=f.id} fixtures|f
        )],
        -where    => $where,
    );

    my $results = $self->dbh->selectall_arrayref(
        $stmt, { Slice => {} }, @bind
    );

    return $results;
}

=item process_fpl_season_history ( PLAYER_ID, FPL_SEASON_INFO )

  Process the FPL current season history for the player given by C<ID>.
  C<ID> should be the mandyville database ID of the player.

  Goes through each gameweek in the season history, and adds the info
  if it doesn't already exist. Doesn't overwrite already stored info.

  If the current gameweek is ongoing, we may have the situation where
  there's partial info in the season history - we deal with this by
  checking if the score in the fixture info is defined, and ignoring
  the fixture info if it isn't.

  Returns the number of inserted rows in total.

  Note that we store the actual decimal value of the player, not the
  integer value returned by the FPL API.

=cut

sub process_fpl_season_history($self, $player_id, $fpl_season_info) {
    my $season = current_season();
    my $count = 0;
    foreach my $gameweek (@$fpl_season_info) {
        my $gw_number = $gameweek->{round};

        if (!defined $gameweek->{team_h_score}) {
            debug "Skipping GW$gw_number, it's incomplete";
            next;
        }

        my $gw_id = $self->gameweeks->get_gameweek_id($season, $gw_number);

        my ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_players_gameweeks',
            -where   => {
                player_id       => $player_id,
                fpl_gameweek_id => $gw_id,
            },
        );

        my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (!defined $id) {
            my $to_insert = {
                player_id       => $player_id,
                fpl_gameweek_id => $gw_id,
                bonus_points    => $gameweek->{bonus},
                bps             => $gameweek->{bps},
                total_points    => $gameweek->{total_points},
                transfers_in    => $gameweek->{transfers_in},
                transfers_out   => $gameweek->{transfers_out},
                selected        => $gameweek->{selected},
                value           => $gameweek->{value} / 10,
            };

            my ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fpl_players_gameweeks',
                -values => $to_insert,
            );

            $count += $self->dbh->do($stmt, undef, @bind);
        }
    }

    return $count;
}

=item update_fixture_info ( FIXTURE_DATA )

  Process the player data for a fixture, inserting player data where
  necessary. The C<FIXTURE_DATA> paramater should be hashref in the
  same format as the JSON shown in
  football-data.org/documentation/api#match. Doesn't attempt to
  process player information for an incomplete fixture.

  Calls out to the football-data API to fetch player info if the
  player isn't previously known.

=cut

sub update_fixture_info($self, $fixture_data) {
    my $fixture_info = $self->fixtures->process_fixture_data($fixture_data);

    return unless defined $fixture_data->{score}->{fullTime}->{homeTeam};

    my $fixture_id   = $fixture_info->{id};

    my $home_id = $fixture_info->{home_team_id};
    $self->_process_team_info(
        $fixture_id, $home_id, $fixture_data, $fixture_data->{homeTeam});

    my $away_id = $fixture_info->{away_team_id};
    return $self->_process_team_info(
        $fixture_id, $away_id, $fixture_data, $fixture_data->{awayTeam});
}

=item update_fpl_id ( PLAYER_ID, FPL_ID )

  Set the FPL entity ID for the player corresponding to C<PLAYER_ID>
  to C<FPL_ID>, if it doesn't already exist.

=cut

sub update_fpl_id($self, $player_id, $fpl_id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'fpl_id',
        -from    => 'players',
        -where   => {
            id => $player_id,
        }
    );

    my ($result) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0 if defined $result;

    ($stmt, @bind) = $self->sqla->update(
        -table => 'players',
        -set   => {
            fpl_id => $fpl_id,
        },
        -where => {
            id => $player_id,
        }
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=item update_understat_fixture_info ( PLAYER_ID, FIXTURE_ID, TEAM_ID, UNDERSTAT_INFO )

  Add the understat information for the fixture event specified by the
  given C<PLAYER_ID>, C<FIXTURE_ID>, C<TEAM_ID>.

  Returns the status of the row update operation, i.e. 1 if the update
  succeeded, 0 if the update failed.

=cut

sub update_understat_fixture_info(
    $self, $player_id, $fixture_id, $team_id, $understat_info) {

    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'goals',
        -from    => 'players_fixtures',
        -where   => {
            fixture_id => $fixture_id,
            player_id  => $player_id,
            team_id    => $team_id,
        }
    );

    my ($goals) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return 0 if defined $goals;

    my $to_insert = {};
    for (qw(goals assists key_passes xG xA xGBuildup xGChain npg npxG
            position)) {

        croak "$_ not provided in understat info"
            unless defined $understat_info->{$_};

        if ($_ eq 'position') {
            my $position_id = $self->_get_position_id($understat_info->{$_});
            $to_insert->{position_id} = $position_id;
        } elsif (exists $UNDERSTAT_MAPPINGS->{$_}) {
            $to_insert->{$UNDERSTAT_MAPPINGS->{$_}} = $understat_info->{$_};
        } else {
            $to_insert->{$_} = $understat_info->{$_};
        }
    }

    ($stmt, @bind) = $self->sqla->update(
        -table => 'players_fixtures',
        -set   => $to_insert,
        -where => {
            fixture_id => $fixture_id,
            player_id  => $player_id,
            team_id    => $team_id,
        }
    );

    return $self->dbh->do($stmt, undef, @bind);
}

sub _process_team_info($self, $fixture_id, $team_id, $fixture_data, $team_info) {
    my $starters = $team_info->{lineup};
    my $subs     = $team_info->{bench};

    my %bookings = map {
        $_->{player}->{id} => $_->{card}
    } @{$fixture_data->{bookings}};

    my %subsOff = map {
        $_->{playerOut}->{id} => $_->{minute}
    } @{$fixture_data->{substitutions}};

    my %subsOn = map {
        $_->{playerIn}->{id} => $_->{minute}
    } @{$fixture_data->{substitutions}};

    # TODO: reduce duplication
    foreach my $player (@$starters) {
        my $player_id = $self->get_by_football_data_id($player->{id});

        $player_id = $self->_get_api_info_and_store($player->{id})->{id}
            if !defined $player_id;

        my $yellow = $self->_has_card($player->{id}, \%bookings, 'YELLOW');
        my $red    = $self->_has_card($player->{id}, \%bookings, 'RED');

        my $minutes_played = exists $subsOff{$player->{id}} ?
                             $subsOff{$player->{id}} : 90;

        my $info = {
            player_id   => $player_id,
            fixture_id  => $fixture_id,
            team_id     => $team_id,
            minutes     => $minutes_played,
            yellow_card => $yellow || 0,
            red_card    => $red || 0,
        };

        $self->_insert_player_fixture($info);
    }

    foreach my $player (@$subs) {
        my $player_id = $self->get_by_football_data_id($player->{id});

        $player_id = $self->_get_api_info_and_store($player->{id})->{id}
            if !defined $player_id;

        my $yellow = $self->_has_card($player->{id}, \%bookings, 'YELLOW');
        my $red    = $self->_has_card($player->{id}, \%bookings, 'RED');

        my $minutes_played = exists $subsOn{$player->{id}} ?
                             90 - $subsOn{$player->{id}} : 0;

        my $info = {
            player_id   => $player_id,
            fixture_id  => $fixture_id,
            team_id     => $team_id,
            minutes     => $minutes_played,
            yellow_card => $yellow || 0,
            red_card    => $red || 0,
        };

        $self->_insert_player_fixture($info);
    }

    return 1;
}

sub _get_api_info_and_store($self, $player_id) {
    my $player_info = $self->_sanitise_name($self->fapi->player($player_id));

    my $to_insert = {
        first_name   => $player_info->{firstName},
        last_name    => $player_info->{lastName},
        country_name => $player_info->{nationality},
    };
    # TODO: Add insert only mode to save a query
    my $id = $self->get_or_insert($player_id, $to_insert);
    return $id;
}

sub _get_teams($self, $id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns  => 't.name',
        -from     => [ -join => qw(
            players_fixtures|pf <=>{f.id=pf.fixture_id} fixtures|f
                                <=>{pf.team_id=t.id}    teams|t
        )],
        -where    => {
            player_id => $id,
        },
    );

    my ($names) = $self->dbh->selectcol_arrayref($stmt, undef, @bind);
    return $names;
}

sub _get_name($self, $id) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [ qw(first_name last_name) ],
        -from    => 'players',
        -where   => {
            'id' => $id,
        }
    );

    my ($first, $last) = $self->dbh->selectrow_array($stmt, undef, @bind);
    return ($first, $last);
}

sub _get_position_id($self, $position) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'positions',
        -where   => {
            'name' => $position,
        }
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    return $id;
}

sub _sanitise_name($self, $player_info) {
    my $first = $player_info->{firstName};
    my $last  = $player_info->{lastName};
    my $full  = $player_info->{name};

    return $player_info if defined $first && defined $last;

    if ($full =~ /\s/) {
        ($first, $last) = $full =~ /(\w+)\s+(.+)$/;
    } elsif (!defined $last) {
        $last = '';
    } elsif (!defined $first) {
        $first = '';
    }

    return {
        firstName   => $first,
        lastName    => $last,
        name        => $full,
        nationality => $player_info->{nationality},
    };
}

sub _has_card($self, $player_id, $booking_info, $colour) {
    return (exists $booking_info->{$player_id}) &&
           ($booking_info->{$player_id} eq $colour . "_CARD");
}

sub _insert_player_fixture($self, $info) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'players_fixtures',
        -where   => {
           player_id  => $info->{player_id},
           fixture_id => $info->{fixture_id},
           team_id    => $info->{team_id},
        },
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    if (!defined $id) {
        my ($stmt, @bind) = $self->sqla->insert(
            -into      => 'players_fixtures',
            -values    => $info,
            -returning => 'id'
        );

        ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);
    }

    return $id;
}

sub _search_understat_and_store($self, $string, $id, $teams) {
    my $results = $self->uapi->search($string);

    return if scalar @$results == 0;

    foreach my $player (@$results) {
        if (any { $_ =~ /\Q$player->{team}\E/ } @$teams) {
            my ($stmt, @bind) = $self->sqla->update(
                -table => 'players',
                -set   => {
                    understat_id => $player->{id},
                },
                -where => {
                    id => $id,
                }
            );

            $self->dbh->do($stmt, undef, @bind);

            return $player;
        }
    }

    return;
}

sub _update_name($self, $id, $fd_id) {
    my $player_info = $self->_sanitise_name($self->fapi->player($fd_id));

    my ($stmt, @bind) = $self->sqla->update(
        -table => 'players',
        -set   => {
            first_name => $player_info->{firstName},
            last_name  => $player_info->{lastName},
        },
        -where => {
            id => $id,
        }
    );

    return $self->dbh->do($stmt, undef, @bind);
}

=back

=cut

1;
