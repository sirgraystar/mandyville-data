package Mandyville::Gameweeks;

use Mojo::Base -base, -signatures;

use Mandyville::API::FPL;
use Mandyville::Database;
use Mandyville::Utils qw(current_season);

use Const::Fast;
use SQL::Abstract::More;

const my $NO_OF_GWS => 38;

=head1 NAME

  Mandyville::Gameweeks - fetch and store gameweek data

=head1 SYNOPSIS

  use Mandyville::Gameweeks;
  my $dbh  = Mandyville::Database->new->rw_db_handle();
  my $sqla = SQL::Abstract::More->new;

  my $gameweeks = Mandyville::Gameweeks->new({
      api  => Mandyville::API::FPL->new,
      dbh  => $dbh,
      sqla => $sqla,
  });

=head1 DESCRIPTION

  This module provides methods for fetching and storing gameweek data,
  where a 'gameweek' refers to a set of matches in the Fantasy Premier
  League game. It primarily uses data from the FPL API to achieve this.

=head1 METHODS

=over

=item api

  An instance of Mandyville::API::FPL.

=item dbh

  A read-write handle to the Mandyville database.

=item sqla

  An instance of SQL::Abstract::More.

=cut

has 'api'  => sub { shift->{api} };
has 'dbh'  => sub { shift->{dbh} };
has 'sqla' => sub { shift->{sqla} };

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
    $options->{api}  //= Mandyville::API::FPL->new;
    $options->{dbh}  //= Mandyville::Database->new->rw_db_handle();
    $options->{sqla} //= SQL::Abstract::More->new;

    my $self = {
        api  => $options->{api},
        dbh  => $options->{dbh},
        sqla => $options->{sqla},
    };

    bless $self, $class;
    return $self;
}

=item add_fixture_gameweeks

  Adds or updates gameweek information for all eligible fixtures in the
  database - that is, any Premier League fixtures which are in the
  current season. Uses the deadline times of the gameweeks to work out
  which gameweek the fixture falls into.

=cut

sub add_fixture_gameweeks($self) {
    my $season = current_season();
    my $gws = $self->_get_gameweeks_for_season($season);

    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(f.id f.fixture_date)],
        -from    => [-join => qw(
            fixtures|f <=>{f.competition_id=c.id} competitions|c
                       <=>{c.country_id=co.id}    countries|co
        )],
        -where   => {
            'f.season' => $season,
            'co.name'  => 'England',
            'c.name'   => 'Premier League',
        }
    );

    my $fixtures =
        $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);

    my $updated = 0;
    foreach my $f (@$fixtures) {
        my $gw =
            $self->_find_gameweek_from_fixture_date($f->{fixture_date}, $gws);

        ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fixtures_fpl_gameweeks',
            -where   => {
                fixture_id => $f->{id}
            }
        );

        my ($f_gw_id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (defined $f_gw_id) {
            ($stmt, @bind) = $self->sqla->update(
                -table => 'fixtures_fpl_gameweeks',
                -set   => {
                    gameweek_id => $gw->{id},
                },
                -where => {
                    id => $f_gw_id,
                }
            );
        } else {
            ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fixtures_fpl_gameweeks',
                -values => {
                    fixture_id  => $f->{id},
                    gameweek_id => $gw->{id},
                }
            );
        }

        $updated += $self->dbh->do($stmt, undef, @bind);
    }

    return $updated;
}

=item get_gameweek_id ( SEASON, GAMEWEEK )

  Fetch the gameweek database ID associated with the given C<SEASON>
  and C<GAMEWEEK>. Dies if no gameweek ID is found.

=cut

sub get_gameweek_id($self, $season, $gameweek) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => 'id',
        -from    => 'fpl_gameweeks',
        -where   => {
            gameweek => $gameweek,
            season   => $season,
        }
    );

    my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

    die "No gameweek found for $season gw $gameweek" if !defined $id;

    return $id;
}

=item process_gameweeks

  Fetch the gameweek data for the current season from the FPL API, and
  store/update the information in the database.

  Return the number of gameweeks processed.

=cut

sub process_gameweeks($self) {
    my $gameweek_info = $self->api->gameweeks;
    my $season = current_season();
    my $updated = 0;

    foreach my $gw (@$gameweek_info) {
        my $gw_number = $gw->{id};
        my $deadline  = $gw->{deadline_time};

        # Sanity check the first gameweek deadline to ensure we're
        # processing the correct season, given that we've made
        # assumptions about the current season.
        if ($gw_number == 1) {
            my ($deadline_year) = $deadline =~ /^(\d{4})/;
            if ($deadline_year != $season) {
                die 'Deadline for first gameweek doesn\'t match season! ' .
                    'Has the next season started?';
            }
        }

        my ($stmt, @bind) = $self->sqla->select(
            -columns => 'id',
            -from    => 'fpl_gameweeks',
            -where   => {
                gameweek => $gw_number,
                season   => $season,
            }
        );

        my ($id) = $self->dbh->selectrow_array($stmt, undef, @bind);

        if (defined $id) {
            ($stmt, @bind) = $self->sqla->update(
                -table => 'fpl_gameweeks',
                -set   => {
                    deadline => $deadline,
                },
                -where => {
                    id => $id
                }
            );
        } else {
            ($stmt, @bind) = $self->sqla->insert(
                -into   => 'fpl_gameweeks',
                -values => {
                    deadline => $deadline,
                    gameweek => $gw_number,
                    season   => $season,
                }
            );
        }

        $updated += $self->dbh->do($stmt, undef, @bind);
    }

    return $updated;
}

=back

=cut

sub _find_gameweek_from_fixture_date($self, $fixture_date, $gw_info) {
    for (my $i = 1; $i < $NO_OF_GWS; $i++) {
        my $gw = $gw_info->[$i];
        my ($gw_date) = $gw->{deadline} =~ /^([\w-]+)\s/;

        if ($fixture_date lt $gw_date) {
            return $gw_info->[$i - 1];
        }
    }
    return $gw_info->[$NO_OF_GWS - 1];
}

sub _get_gameweeks_for_season($self, $season) {
    my ($stmt, @bind) = $self->sqla->select(
        -columns => [qw(id gameweek deadline)],
        -from    => 'fpl_gameweeks',
        -where   => {
            season => $season,
        }
    );

    my $gws = $self->dbh->selectall_arrayref($stmt, { Slice => {} }, @bind);
    return $gws;
}

1;

