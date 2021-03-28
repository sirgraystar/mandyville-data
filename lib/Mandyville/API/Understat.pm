package Mandyville::API::Understat;

use Mojo::Base 'Mandyville::API', -signatures;

use Const::Fast;
use Mojo::DOM;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(url_escape);

=head1 NAME

  Mandyville::API::Understat - interact with the understat.com

=head1 SYNOPSIS

  use Mandyville::API::Understat;
  my $api = Mandyville::API::Understat->new;

=head1 DESCRIPTION

  This module provides methods for fetching and parsing information
  from understat.com. Since understat doesn't have an API, we parse
  the JSON returned in the pages.

=cut

const my $BASE_URL => "https://understat.com/";
const my $PARSERS  => {
    'main/getPlayersName' => sub { return $_[1] },
    'player'              => \&_parse_match_info,
};

=head1 METHODS

=over

=item dom

  An instance of Mojo::DOM

=cut

has 'dom' => sub { Mojo::DOM->new };

=item player ( ID )

=cut

sub player($self, $id) {
    return $self->get("player/$id");
}

=item search ( NAME )

  Searches for a player with the given C<NAME>. Name should be the
  full name of the player to get the most accurate reuslts, but
  partial searches will work as well.

  Returns an arrayref of matching results. Dies if a success key
  isn't returned from the API.

=cut

sub search($self, $name) {
    my $response = $self->get('main/getPlayersName/' . url_escape($name));

    return $response->{response}->{players}
        if defined $response->{response}->{success};

    die "Unknown error from understat: search for $name";
}

=back

=cut

sub _get($self, $path) {
    my $body = $self->ua->get($BASE_URL . $path)->res->body;

    $path =~ s/\/[^\/]+(?:\/?)$//;

    return $PARSERS->{$path}->($self, $body);
}

sub _parse_match_info($self, $body) {
    my $match_info = $self->dom->parse($body)->find('script')->[4]->text;

    $match_info =~ /matchesData/ or die "No match data found in script tag";

    # Strip everything away except the JSON string and attempt to parse it
    # Convert the hex escape sequences to their ASCII versions
    $match_info =~ s/var matchesData=JSON.parse\('//;
    $match_info =~ s/'\);//g;
    $match_info =~ s/\\\\x(\w{2})/chr(hex($1))/eg;

    return $match_info;
}

sub _rate_limit($self) {
    return 1;
}

1;

