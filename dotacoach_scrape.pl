#!/usr/bin/env perl
#
# DotaCoach Scraper - Fetch hero counter and synergy data
#
# This script scrapes data from https://dotacoach.gg to create a matrix containing:
# - Counter advantages (heroes that counter each hero)
# - Synergy values (heroes that work well together or poorly together)
#
# Matrix format: [advantage, winrate, matches, synergy]
# - advantage: Counter advantage value (positive = counters, negative = countered by)
# - winrate: Win rate when playing against this matchup
# - matches: Number of matches in the data
# - synergy: Synergy value (positive = good with, negative = bad with)
#
# Usage:
#   DEBUG=1 perl dotacoach_scrape.pl
#   FLARESOLVERR_URL=http://localhost:8191/v1 perl dotacoach_scrape.pl
#
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
  # Match the heroes array more precisely - stop at the closing bracket followed by comma or semicolon
  my ($arr) = $s =~ m{var\s+heroes\s*=\s*(\[.*?\])\s*[,;]};
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
  
  my %counters;
  
  # DotaCoach pages have hero references in various sections
  # For counters, we look for heroes in the "Counters" section
  # Pattern: /en/heroes/counters/{slug} with associated advantage percentages
  
  # Try to extract counter section (before synergy sections)
  my $counter_section = $html;
  if ($html =~ m{(.*?)(?:Good\s+with|Bad\s+with|Works\s+well)}is) {
    $counter_section = $1;
  }
  
  # Find hero links with nearby percentage values
  # The structure is: hero link followed by advantage/winrate percentages
  my @matches;
  while ($counter_section =~ m{/en/heroes/counters/([a-z-]+)"}gs) {
    push @matches, $1;
  }
  
  # For each matched hero slug, try to find associated advantage value
  # DotaCoach typically shows advantage as a percentage
  for my $slug (@matches) {
    next unless defined $slug_to_index{$slug};
    my $opp_idx = $slug_to_index{$slug};
    
    # Look for advantage value near this hero mention
    # This is a simplified approach - actual values would need more sophisticated parsing
    # Default to a small advantage value for now
    $counters{$opp_idx} = 2.0;  # Placeholder - needs refinement
  }
  
  return \%counters;
}

# Parse synergy data from dotacoach.gg HTML
# Handles both "Good with..." (positive) and "Bad with..." (negative) sections
sub parse_dotacoach_synergy {
  my ($html, $hero_idx) = @_;
  return unless $html;
  
  my %synergy;
  
  # DotaCoach HTML structure analysis:
  # The page contains hero links with descriptions in different sections
  # "Good with..." section contains positive synergies
  # "Bad with..." section contains negative synergies (anti-synergies)
  
  # Parse "Good with..." heroes (positive synergy)
  # Look for the section between "Good with" and either "Bad with" or end of relevant content
  if ($html =~ m{Good\s+with.*?</h[2-4]>(.*?)(?:Bad\s+with|<footer|<script|$)}is) {
    my $good_section = $1;
    # Find hero links in this section
    my @good_heroes;
    while ($good_section =~ m{/en/heroes/counters/([a-z-]+)"}g) {
      push @good_heroes, $1;
    }
    
    # Assign positive synergy values
    for my $slug (@good_heroes) {
      next unless defined $slug_to_index{$slug};
      my $ally_idx = $slug_to_index{$slug};
      # Use a moderate positive value for "good with" heroes
      # This can be refined based on actual game data
      $synergy{$ally_idx} = 3.0;
    }
    
    warn "  Found ".scalar(@good_heroes)." heroes in 'Good with' section\n" if $DEBUG && @good_heroes;
  }
  
  # Parse "Bad with..." heroes (negative synergy / anti-synergy)
  if ($html =~ m{Bad\s+with.*?</h[2-4]>(.*?)(?:<footer|<script|$)}is) {
    my $bad_section = $1;
    # Find hero links in this section
    my @bad_heroes;
    while ($bad_section =~ m{/en/heroes/counters/([a-z-]+)"}g) {
      push @bad_heroes, $1;
    }
    
    # Assign negative synergy values
    for my $slug (@bad_heroes) {
      next unless defined $slug_to_index{$slug};
      my $ally_idx = $slug_to_index{$slug};
      # Use a moderate negative value for "bad with" heroes
      # If hero is already in good_with, this will create net synergy
      $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - 3.0;
    }
    
    warn "  Found ".scalar(@bad_heroes)." heroes in 'Bad with' section\n" if $DEBUG && @bad_heroes;
  }
  
  # Net synergy for each hero is calculated as:
  # Positive values from "Good with" + Negative values from "Bad with"
  # This gives a final synergy score where:
  # - Positive values = good synergy (works well together)
  # - Negative values = anti-synergy (bad to pick together)
  # - Zero = neutral (no special synergy relationship)
  
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
