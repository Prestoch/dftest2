#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use POSIX qw/strftime/;
use HTTP::Tiny;

my $DEBUG = ($ENV{DEBUG} || grep { $_ eq '--debug' } @ARGV) ? 1 : 0;

# Autoflush output
$| = 1;

my ($http) = (HTTP::Tiny->new(
  agent => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  timeout => 60,
  verify_SSL => 0
));

my $FLARESOLVERR_URL = $ENV{FLARESOLVERR_URL} // 'http://localhost:8191/v1';
my $FLARE_SESSION_ID;
my $FLARE_HEALTHY;

sub flare_healthy {
  return $FLARE_HEALTHY if defined $FLARE_HEALTHY;
  return $FLARE_HEALTHY = 0 unless $FLARESOLVERR_URL;
  my $h = $FLARESOLVERR_URL;
  $h =~ s{/v1$}{/health};
  my $r = $http->get($h);
  $FLARE_HEALTHY = ($r->{success} && ($r->{content} || '') =~ /ok/i) ? 1 : 0;
  warn "FlareSolverr health: ".($FLARE_HEALTHY ? 'ok' : 'unavailable')."\n" if $DEBUG;
  return $FLARE_HEALTHY;
}

sub flare_session_create {
  return if !$FLARESOLVERR_URL || $FLARE_SESSION_ID;
  my $r = $http->post($FLARESOLVERR_URL, {
    headers => {'Content-Type' => 'application/json'},
    content => '{"cmd":"sessions.create"}'
  });
  if ($r->{success}) {
    my $j;
    eval { $j = decode_json($r->{content}); };
    $FLARE_SESSION_ID = $j->{session} if !$@ && $j && $j->{session};
    warn "Created FlareSolverr session: $FLARE_SESSION_ID\n" if $DEBUG && $FLARE_SESSION_ID;
  }
}

sub flare_session_destroy {
  return unless $FLARE_SESSION_ID;
  my $p = '{"cmd":"sessions.destroy","session":"'.$FLARE_SESSION_ID.'"}';
  $http->post($FLARESOLVERR_URL, {
    headers => {'Content-Type' => 'application/json'},
    content => $p
  });
  $FLARE_SESSION_ID = undef;
}

sub fetch_html {
  my ($url) = @_;
  if ($FLARESOLVERR_URL && flare_healthy()) {
    flare_session_create();
    my $p = '{"cmd":"request.get","url":"'.$url.'","maxTimeout":60000'.
            ($FLARE_SESSION_ID ? ',"session":"'.$FLARE_SESSION_ID.'"' : '').
            ',"headers":{"User-Agent":"'.$http->{agent}.'"}}';
    my $r = $http->post($FLARESOLVERR_URL, {
      headers => {'Content-Type' => 'application/json'},
      content => $p
    });
    if ($r->{success}) {
      my $j;
      eval { $j = decode_json($r->{content}); };
      return $j->{solution}{response} if !$@ && $j && $j->{status} && $j->{status} eq 'ok' && $j->{solution} && $j->{solution}{response};
    }
  }
  my $r2 = $http->get($url);
  return $r2->{success} ? $r2->{content} : undef;
}

sub norm {
  my ($t) = @_;
  $t //= '';
  $t =~ s/&[^;]+;//g;
  $t =~ s/'//g;
  $t =~ s/^\s+|\s+$//g;
  return $t;
}

sub slug_from_name {
  my ($n) = @_;
  $n =~ s/'//g;
  $n =~ s/ /-/g;
  $n =~ tr/[A-Z]/[a-z]/;
  return $n;
}

my (@heroes, @heroes_bg, @heroes_wr, @win_rates, @synergy_rates, %slug_to_index);

sub get_heroes_from_cs {
  my $cs = 'cs.json';
  return unless -f $cs;
  open my $fh, '<', $cs or return;
  local $/;
  my $s = <$fh>;
  close $fh;
  my ($arr) = $s =~ m{var\s+heroes\s*=\s*(\[[^;]+\])};
  return unless $arr;
  my $j;
  eval { $j = decode_json($arr); };
  return if $@ || ref $j ne 'ARRAY';
  @heroes = @$j;
  for (my $i = 0; $i < @heroes; $i++) {
    my $slug = lc $heroes[$i];
    $slug =~ s/'//g;
    $slug =~ s/\s+/-/g;
    $slug =~ s/[^a-z0-9-]+//g;
    $slug_to_index{$slug} = $i;
    $heroes_bg[$i] //= "";
    $heroes_wr[$i] //= sprintf('%.2f', 50.0);
  }
  warn "Loaded heroes from cs.json: ".scalar(@heroes)."\n" if $DEBUG;
}

# Parse counter data from dotacoach.gg HTML
sub parse_dotacoach_counters {
  my ($html, $hero_idx) = @_;
  return unless $html;
  
  # DotaCoach uses a different HTML structure - look for hero links and advantage data
  # Pattern: /en/heroes/counters/{slug} with nearby advantage values
  my %counters;
  
  # This is a simplified parser - you may need to adjust based on actual HTML structure
  while ($html =~ m{/en/heroes/counters/([a-z-]+).*?([0-9.]+)%}gs) {
    my ($slug, $advantage) = ($1, $2);
    next unless defined $slug_to_index{$slug};
    my $opp_idx = $slug_to_index{$slug};
    $counters{$opp_idx} = $advantage;
  }
  
  return \%counters;
}

# Parse synergy data from dotacoach.gg HTML
sub parse_dotacoach_synergy {
  my ($html, $hero_idx) = @_;
  return unless $html;
  
  my %synergy;
  
  # Look for "Good with" section - heroes that synergize well
  # Pattern similar to counters but in synergy section
  # For now, we'll use a placeholder - actual parsing needs HTML analysis
  
  # The HTML has hero links like: /en/heroes/counters/{slug}
  # with descriptions about synergy
  # We need to identify which section is "Good with" vs counters
  
  # Simplified: assume positive values in certain sections are synergies
  # This needs refinement based on actual HTML structure
  
  return \%synergy;
}

sub get_data_for_hero {
  my ($idx) = @_;
  my $slug = slug_from_name($heroes[$idx]);
  my $url = 'https://dotacoach.gg/en/heroes/counters/'.$slug;
  
  warn "Getting DotaCoach data for $heroes[$idx] at $url\n" if $DEBUG;
  
  my $html = fetch_html($url);
  return unless $html;
  
  # Parse counter data
  my $counters = parse_dotacoach_counters($html, $idx);
  for my $opp_idx (keys %$counters) {
    my $adv = $counters->{$opp_idx};
    # Format: [advantage, winrate, matches, synergy]
    # For now, use placeholder values for winrate and matches
    $win_rates[$idx][$opp_idx] = [
      sprintf('%.4f', $adv),
      sprintf('%.4f', 50.0),  # Placeholder
      0,  # Placeholder
      sprintf('%.4f', 0.0)  # Synergy placeholder
    ];
  }
  
  # Parse synergy data
  my $synergy = parse_dotacoach_synergy($html, $idx);
  for my $ally_idx (keys %$synergy) {
    my $syn = $synergy->{$ally_idx};
    # Store synergy in the 4th element of the matrix
    if ($win_rates[$idx][$ally_idx]) {
      $win_rates[$idx][$ally_idx][3] = sprintf('%.4f', $syn);
    } else {
      $win_rates[$idx][$ally_idx] = [
        sprintf('%.4f', 0.0),  # Advantage placeholder
        sprintf('%.4f', 50.0),  # Winrate placeholder
        0,  # Matches placeholder
        sprintf('%.4f', $syn)  # Synergy
      ];
    }
  }
}

sub get_all_data {
  warn "Fetching DotaCoach data for all heroes (".scalar(@heroes).")\n" if $DEBUG;
  for (my $i = 0; $i < @heroes; $i++) {
    get_data_for_hero($i);
  }
  my $filled = 0;
  for my $h (0..$#heroes) {
    $filled++ if ref $win_rates[$h] eq 'ARRAY';
  }
  warn "Data fetched for $filled heroes\n" if $DEBUG;
}

sub write_output {
  open my $fh, '>', 'cs_dotacoach.json' or die $!;
  my $j = JSON::PP->new;
  
  # Base arrays
  print $fh 'var heroes = ', $j->encode([@heroes]);
  print $fh ', heroes_bg = ', $j->encode([@heroes_bg]);
  print $fh ', heroes_wr = ', $j->encode([@heroes_wr]);
  
  # Matrix now has 4 elements: [advantage, winrate, matches, synergy]
  print $fh ', win_rates = ', $j->encode([@win_rates]);
  
  print $fh ', update_time = "', strftime("%Y-%m-%d", localtime), '";';
  print $fh "\n";
  close $fh;
}

warn "Starting DotaCoach scrape\n" if $DEBUG;

# Load heroes from existing cs.json
get_heroes_from_cs();
if (!@heroes) {
  die "Failed to load heroes from cs.json";
}

# Get counter and synergy data
get_all_data();

# Write output
write_output();
flare_session_destroy();

warn "Successfully wrote cs_dotacoach.json with ".scalar(@heroes)." heroes\n" if $DEBUG;
