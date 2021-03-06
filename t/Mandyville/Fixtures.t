#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;

use Mandyville::Countries;
use Mandyville::Competitions;
use Mandyville::Database;
use Mandyville::Teams;
use Mandyville::Utils qw(find_file);

use Mojo::File;
use Mojo::JSON qw(decode_json);
use SQL::Abstract::More;
use Test::Exception;
use Test::More;

######
# TEST use/require
######

use_ok 'Mandyville::Fixtures';
require_ok 'Mandyville::Fixtures';

use Mandyville::Fixtures;

######
# TEST get_or_insert, find_fixture_from_understat_data,
#      process_understat_fixture_data, is_at_home
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $teams = Mandyville::Teams->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
    });

    my $fixtures = Mandyville::Fixtures->new({
        dbh   => $dbh->rw_db_handle(),
        sqla  => $sqla,
        teams => $teams,
    });

    dies_ok { $fixtures->get_or_insert } 'get_or_insert: dies without args';

    my $season = '2018';
    my $country = 'Argentina';
    my $comp_name = 'Primera B Nacional';
    my $country_id = $countries->get_country_id($country);
    my $comp_data = $comp->get_or_insert($comp_name, $country_id, 2000, 1);

    my $home = 'Atlético de Rafaela';
    my $away = 'Villa Dálmine';
    my $home_team_data = $teams->get_or_insert($home, 1);
    my $away_team_data = $teams->get_or_insert($away, 2);
    my $home_team_id = $home_team_data->{id};
    my $away_team_id = $away_team_data->{id};

    throws_ok { $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, {}
    ) } qr/missing fixture_date/,
        'get_or_insert: dies on insert without match info';

    my $fixture_date = '2018-01-01';
    my $match_info = {
        fixture_date => $fixture_date,
    };

    my $fixture_data = $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, $match_info
    );

    my $id = $fixture_data->{id};

    ok( $id, 'get_or_insert: inserts with correct data' );

    ok( !$fixture_data->{home_team_goals},
        'get_or_insert: match info isn\'t defined' );

    $match_info = {
        fixture_date    => $fixture_date,
        winning_team_id => $home_team_id,
        home_team_goals => 1,
        away_team_goals => 3,
    };

    $fixture_data = $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, $match_info
    );

    cmp_ok( $fixture_data->{id}, '==', $id, 'get_or_insert: returns same ID' );

    ok( $fixture_data->{home_team_goals},
        'get_or_insert: match data inserted for existing fixture' );

    $match_info->{fixture_date} = '2018-02-01';

    $fixture_data = $fixtures->get_or_insert(
        $comp_data->{id}, $home_team_id, $away_team_id, $season, $match_info
    );

    cmp_ok( $fixture_data->{fixture_date}, 'ne', $fixture_date,
            'get_or_insert: fixture date correctly updated' );

    $teams->get_or_insert_team_comp($home_team_id, $season, $comp_data->{id});
    $teams->get_or_insert_team_comp($away_team_id, $season, $comp_data->{id});

    dies_ok { $fixtures->find_fixture_from_understat_data }
              'find_fixture_from_understat_data: dies without args';

    my $understat_data = {
        h_team => $home,
        a_team => $away,
        season => 2018,
    };

    my $fixture_id = $fixtures->find_fixture_from_understat_data(
        $understat_data, [$comp_data->{id}]
    );

    cmp_ok( $fixture_id, '==', $id,
            'find_fixture_from_understat_data: returns correct ID' );

    $understat_data->{h_team} = 'Liverpool';

    throws_ok { $fixtures->find_fixture_from_understat_data(
                    $understat_data, [$comp_data->{id}]
                ) }
                qr/No competition ID found/,
                'find_fixture_from_understat_data: dies if comp not found';

    $understat_data->{season} = 2017;

    ok( !$fixtures->find_fixture_from_understat_data(
            $understat_data, [$comp_data->{id}]
        ), 'find_fixture_from_understat_data: returns undef if old season' );

    my $understat_match_data = {
        deep_passes     => 3,
        draw_chance		=> 0.4,
        ppda			=> 2.3,
        loss_chance		=> 0.1,
        shots			=> 3,
        shots_on_target	=> 1,
        win_chance		=> 0.5,
        xg				=> 0.5,
    };

    dies_ok { $fixtures->process_understat_fixture_data }
              'process_understat_fixture_data: dies without args';

    my $ftp_id = $fixtures->process_understat_fixture_data(
        $fixture_id, $home_team_id, $understat_match_data);

    ok( $ftp_id, 'process_understat_fixture_data: correctly inserts data' );

    my $new_id = $fixtures->process_understat_fixture_data(
        $fixture_id, $away_team_id, $understat_match_data);

    cmp_ok( $ftp_id, '!=', $new_id,
            'process_understat_fixture_data: correctly inserts other data' );

    my $same_id = $fixtures->process_understat_fixture_data(
        $fixture_id, $away_team_id, $understat_match_data);

    cmp_ok( $new_id, '==', $same_id,
            'process_understat_fixture_data: returns same id for same data' );

    dies_ok { $fixtures->is_at_home } 'is_at_home: dies without args';

    cmp_ok( $fixtures->is_at_home($fixture_id, $away_team_id), '==', 0,
            'is_at_home: correct for away team' );

    cmp_ok( $fixtures->is_at_home($fixture_id, $home_team_id), '==', 1,
            'is_at_home: correct for home team' );
}

######
# TEST process_fixture_data
######

{
    my $dbh  = Mandyville::Database->new;
    my $sqla = SQL::Abstract::More->new;
    my $teams = Mandyville::Teams->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $countries = Mandyville::Countries->new({
        dbh => $dbh->rw_db_handle(),
    });

    my $comp = Mandyville::Competitions->new({
        countries => $countries,
        dbh       => $dbh->rw_db_handle(),
    });

    my $fixtures = Mandyville::Fixtures->new({
        comps => $comp,
        dbh   => $dbh->rw_db_handle(),
        sqla  => $sqla,
        teams => $teams,
    });

    my $country_id = $countries->get_country_id('Europe');
    my $comp_id = $comp->get_or_insert(
        'UEFA Champions League', $country_id, '2001', 1
    );

    dies_ok { $fixtures->process_fixture_data() }
              'process_fixture_data: dies without args';

    my $fixture_info = _load_test_json('match.json');

    my $data = $fixtures->process_fixture_data($fixture_info);

    ok( $data->{id}, 'process_fixture_data: inserts correctly' );

    cmp_ok( $data->{away_team_goals}, '==', 1,
            'process_fixture_data: correct match info' );

    cmp_ok( $data->{season}, '==', '2017',
            'process_fixture_data: correct season returned' );

    cmp_ok( $data->{fixture_date}, 'eq', '2018-05-26',
            'process_fixture_data: correct fixture date' );

    delete $fixture_info->{utcDate};

    throws_ok { $fixtures->process_fixture_data($fixture_info) }
                qr/fixture date/, 'process_fixture_data: dies without score';
}

done_testing();

sub _load_test_json($filename) {
    my $full_path = find_file("t/data/$filename");
    my $json = Mojo::File->new($full_path)->slurp;
    return decode_json($json);
}

