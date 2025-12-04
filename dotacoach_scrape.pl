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
# Prerequisites:
#   npm install -g playwright
#   playwright install chromium
#
# Usage:
#   DEBUG=1 perl dotacoach_scrape.pl
#
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use POSIX qw/strftime/;
use File::Temp qw/tempfile/;

my $DEBUG = ($ENV{DEBUG} || grep { $_ eq '--debug' } @ARGV) ? 1 : 0;

# Autoflush output
$| = 1;

# Fetch HTML using Playwright with automatic "Show More" button clicking
sub fetch_html {
  my ($url, $expand_sections) = @_;
  
  # Create a temporary JavaScript file for Playwright
  my ($fh, $jsfile) = tempfile('dotacoach_XXXX', SUFFIX => '.js', TMPDIR => 1);
  
  my $js = <<'ENDJS';
const playwright = require('playwright');

(async () => {
  const browser = await playwright.chromium.launch({ headless: true });
  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
  });
  const page = await context.newPage();
  
  const url = process.argv[2];
  const expandSections = process.argv[3] === 'true';
  
  await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
  
  if (expandSections) {
    // Wait a bit for initial content to load
    await page.waitForTimeout(2000);
    
    // Click all "Show More" buttons multiple times to reveal all heroes
    for (let i = 0; i < 10; i++) {
      const buttons = await page.$$('button:has-text("Show More")');
      if (buttons.length === 0) break;
      
      for (const button of buttons) {
        try {
          await button.click();
          await page.waitForTimeout(500);
        } catch (e) {
          // Button might not be clickable, skip
        }
      }
    }
    
    // Wait for content to settle
    await page.waitForTimeout(2000);
  }
  
  const html = await page.content();
  console.log(html);
  
  await browser.close();
})();
ENDJS
  
  print $fh $js;
  close $fh;
  
  my $expand_arg = $expand_sections ? 'true' : 'false';
  my $cmd = "node $jsfile '$url' $expand_arg 2>/dev/null";
  my $html = `$cmd`;
  unlink $jsfile;
  
  return $html || undef;
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
  # Try both with and without space in "Bad against"
  my $bad_against_html = '';
  if ($html =~ m{Bad\s+against.*?<table[^>]*>.*?<tbody>(.*?)</tbody>}is) {
    $bad_against_html = $1;
  }
  
  if ($bad_against_html) {
    my $bad_count = 0;
    
    # Split into table rows to process each hero separately
    my @rows = split(/<tr/i, $bad_against_html);
    foreach my $row (@rows) {
      next unless $row =~ m{href="/en/heroes/counters/([a-z-]+)"};
      my $slug = $1;
      next unless defined $slug_to_index{$slug};
      my $opp_idx = $slug_to_index{$slug};
      
      # Try multiple patterns for percentage extraction:
      # Pattern 1: Malformed HTML with gt="" -X.X< (most common for negative values)
      if ($row =~ m{gt=""\s*-([0-9.]+)<}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
        next;
      }
      # Pattern 2: Standard format with minus sign before percentage
      if ($row =~ m{>-([0-9.]+)\s*%<}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
        next;
      }
      # Pattern 3: Look for any -X.X pattern in text
      if ($row =~ m{[^0-9]-([0-9.]+)}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
        next;
      }
      # Pattern 4: Normal positive percentage (convert to negative)
      if ($row =~ m{<p[^>]*>([0-9.]+)<!--\s*-->%</p>}s) {
        my $pct = $1;
        $counters{$opp_idx} = -1 * $pct;
        $bad_count++;
        next;
      }
    }
    warn "  Found $bad_count heroes in 'Bad against' section\n" if $DEBUG;
  } else {
    warn "  Found 0 heroes in 'Bad against' section\n" if $DEBUG;
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
  my $bad_with_html = '';
  if ($html =~ m{Bad\s+with.*?<table[^>]*>.*?<tbody>(.*?)</tbody>}is) {
    $bad_with_html = $1;
  }
  
  if ($bad_with_html) {
    my $bad_count = 0;
    
    # Split into table rows to process each hero separately
    my @rows = split(/<tr/i, $bad_with_html);
    foreach my $row (@rows) {
      next unless $row =~ m{href="/en/heroes/counters/([a-z-]+)"};
      my $slug = $1;
      next unless defined $slug_to_index{$slug};
      my $ally_idx = $slug_to_index{$slug};
      
      # Try multiple patterns for percentage extraction:
      # Pattern 1: Malformed HTML with gt="" -X.X< (most common for negative values)
      if ($row =~ m{gt=""\s*-([0-9.]+)<}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
        next;
      }
      # Pattern 2: Standard format with minus sign before percentage
      if ($row =~ m{>-([0-9.]+)\s*%<}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
        next;
      }
      # Pattern 3: Look for any -X.X pattern in text
      if ($row =~ m{[^0-9]-([0-9.]+)}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
        next;
      }
      # Pattern 4: Normal positive percentage (convert to negative)
      if ($row =~ m{<p[^>]*>([0-9.]+)<!--\s*-->%</p>}s) {
        my $pct = $1;
        $synergy{$ally_idx} = ($synergy{$ally_idx} || 0) - $pct;
        $bad_count++;
        next;
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
  
  my $html = fetch_html($url, 0);  # 0 = don't expand sections (not needed for win rate page)
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
  
  # Fetch hero's general win rate from main page (no need to expand sections)
  my $hero_wr = get_hero_winrate($slug);
  $heroes_wr[$idx] = sprintf('%.2f', $hero_wr);
  
  # Fetch counter and synergy data from counters page WITH section expansion
  my $html = fetch_html($url, 1);  # 1 = expand "Show More" buttons
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

warn "Successfully wrote cs_dotacoach.json with ".scalar(@heroes)." heroes\n" if $DEBUG;
