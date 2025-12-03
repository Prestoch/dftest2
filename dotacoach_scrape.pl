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
# "Good against" = positive advantage (heroes we counter)
# "Bad against" = negative advantage (heroes that counter us)
sub parse_dotacoach_counters {
  my ($html, $hero_idx) = @_;
  return unless $html;
  
  my %counters;
  
  # Parse "Good against" section (heroes this hero counters)
  # These get positive advantage values
  if ($html =~ m{Good\s+against.*?<table.*?<tbody>(.*?)</tbody>}is) {
    my $good_against = $1;
    # Match hero slug and percentage in table rows
    while ($good_against =~ m{href="/en/heroes/counters/([a-z-]+)".*?<p[^>]*>([0-9.]+)<!--\s*-->%</p>}gs) {
      my ($slug, $pct) = ($1, $2);
      next unless defined $slug_to_index{$slug};
      my $opp_idx = $slug_to_index{$slug};
      $counters{$opp_idx} = $pct;
    }
    warn "  Found ".scalar(keys %counters)." heroes in 'Good against' section\n" if $DEBUG;
  }
  
  # Parse "Bad against" section (heroes that counter this hero)
  # These get negative advantage values
  # Note: The HTML has malformed attributes for negative values like: gt="" -6.4<="" --="" <="" p="">
  if ($html =~ m{Bad\s+against.*?<table.*?<tbody>(.*?)</tbody>}is) {
    my $bad_against = $1;
    my $bad_count = 0;
    
    # Split into table rows to process each hero separately
    my @rows = split(/<tr/, $bad_against);
    foreach my $row (@rows) {
      next unless $row =~ m{href="/en/heroes/counters/([a-z-]+)"};
      my $slug = $1;
      next unless defined $slug_to_index{$slug};
      my $opp_idx = $slug_to_index{$slug};
      
      # Try multiple patterns for percentage extraction:
      # Pattern 1: Normal positive percentage (shouldn't happen in Bad against, but just in case)
      if ($row =~ m{<p[^>]*>([0-9.]+)<!--\s*-->%</p>}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
      }
      # Pattern 2: Malformed HTML with gt="" -X.X<
      elsif ($row =~ m{gt=""\s*-([0-9.]+)<}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
      }
      # Pattern 3: Look for -X.X anywhere in the row after the hero link
      elsif ($row =~ m{-([0-9.]+)\s*%}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
      }
    }
    warn "  Found $bad_count heroes in 'Bad against' section\n" if $DEBUG;
  }
  
  return \%counters;
}

# Parse synergy data from dotacoach.gg HTML
# Handles both "Good with..." (positive) and "Bad with..." (negative) sections
sub parse_dotacoach_synergy {
  my ($html, $hero_idx) = @_;
  return unless $html;
  
  my %synergy;
  
  # Parse "Good with" section (heroes that work well together)
  # These get positive synergy values
  if ($html =~ m{Good\s+with.*?<table.*?<tbody>(.*?)</tbody>}is) {
    my $good_with = $1;
    my $good_count = 0;
    # Match hero slug and percentage in table rows
    while ($good_with =~ m{href="/en/heroes/counters/([a-z-]+)".*?<p[^>]*>([0-9.]+)<!--\s*-->%</p>}gs) {
      my ($slug, $pct) = ($1, $2);
      next unless defined $slug_to_index{$slug};
      my $ally_idx = $slug_to_index{$slug};
      $synergy{$ally_idx} = $pct;
      $good_count++;
    }
    warn "  Found $good_count heroes in 'Good with' section\n" if $DEBUG && $good_count;
  }
  
  # Parse "Bad with" section (heroes that work poorly together)
  # These get negative synergy values
  # Note: The HTML has malformed attributes for negative values like: gt="" -6.9<="" --="" <="" p="">
  if ($html =~ m{Bad\s+with.*?<table.*?<tbody>(.*?)</tbody>}is) {
    my $bad_with = $1;
    my $bad_count = 0;
    
    # Split into table rows to process each hero separately
    my @rows = split(/<tr/, $bad_with);
    foreach my $row (@rows) {
      next unless $row =~ m{href="/en/heroes/counters/([a-z-]+)"};
      my $slug = $1;
      next unless defined $slug_to_index{$slug};
      my $ally_idx = $slug_to_index{$slug};
      
      # Try multiple patterns for percentage extraction:
      # Pattern 1: Normal positive percentage (shouldn't happen in Bad with, but just in case)
      if ($row =~ m{<p[^>]*>([0-9.]+)<!--\s*-->%</p>}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
      }
      # Pattern 2: Malformed HTML with gt="" -X.X<
      elsif ($row =~ m{gt=""\s*-([0-9.]+)<}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
      }
      # Pattern 3: Look for -X.X anywhere in the row after the hero link
      elsif ($row =~ m{-([0-9.]+)\s*%}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
      }
    }
    warn "  Found $bad_count heroes in 'Bad with' section\n" if $DEBUG && $bad_count;
  }
  
  # Net synergy for each hero is calculated as:
  # Positive values from "Good with" + Negative values from "Bad with"
  # This gives a final synergy score where:
  # - Positive values = good synergy (works well together)
  # - Negative values = anti-synergy (bad to pick together)
  # - Zero = neutral (no special synergy relationship)
  
  return \%synergy;
}

# Parse hero win rate from hero's main page
sub get_hero_winrate {
  my ($slug) = @_;
  my $url = 'https://dotacoach.gg/en/heroes/'.$slug;
  
  warn "  Fetching win rate from $url\n" if $DEBUG;
  
  my $html = fetch_html($url);
  return 50.0 unless $html;
  
  # Pattern: <h2...>Win Rate <span style="color:rgb(86,188,77)">53.3<!-- -->%</span></h2>
  if ($html =~ m{Win\s+Rate.*?<span[^>]*>([0-9.]+)<!--\s*-->%</span>}is) {
    my $wr = $1;
    warn "    Win rate: $wr%\n" if $DEBUG;
    return $wr;
  }
  
  return 50.0;  # Default if not found
}

sub get_data_for_hero {
  my ($idx) = @_;
  my $slug = slug_from_name($heroes[$idx]);
  my $url = 'https://dotacoach.gg/en/heroes/counters/'.$slug;
  
  warn "Getting DotaCoach data for $heroes[$idx] at $url\n" if $DEBUG;
  
  # Fetch hero's general win rate from main page
  my $hero_wr = get_hero_winrate($slug);
  $heroes_wr[$idx] = sprintf('%.2f', $hero_wr);
  
  # Fetch counter and synergy data from counters page
  my $html = fetch_html($url);
  return unless $html;
  
  # Parse counter data (Good against / Bad against)
  my $counters = parse_dotacoach_counters($html, $idx);
  for my $opp_idx (keys %$counters) {
    my $adv = $counters->{$opp_idx};
    # Format: [advantage, winrate, matches, synergy]
    # For now, use placeholder values for winrate and matches
    $win_rates[$idx][$opp_idx] = [
      sprintf('%.4f', $adv),
      sprintf('%.4f', 50.0),  # Placeholder - actual matchup winrate
      0,  # Placeholder - matches count
      sprintf('%.4f', 0.0)  # Synergy placeholder (will be filled below)
    ];
  }
  
  # Parse synergy data (Good with / Bad with)
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
