package  Demeter::UI::Athena::ColumnSelection;

=for Copyright
 .
 Copyright (c) 2006-2010 Bruce Ravel (bravel AT bnl DOT gov).
 All rights reserved.
 .
 This file is free software; you can redistribute it and/or
 modify it under the same terms as Perl itself. See The Perl
 Artistic License.
 .
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut

use strict;
use warnings;

use Wx qw( :everything);
use base qw(Wx::Dialog);
use Wx::Event qw(EVT_RADIOBUTTON EVT_CHECKBOX EVT_CHOICE);
use Wx::Perl::Carp;
use Demeter::UI::Wx::SpecialCharacters qw(:all);

use List::MoreUtils qw(minmax);

my $contents_font_size = Wx::SystemSettings::GetFont(wxSYS_DEFAULT_GUI_FONT)->GetPointSize - 1;

sub new {
  my ($class, $parent, $app, $data) = @_;

  my $this = $class->SUPER::new($parent, -1, "Athena: Column selection",
				wxDefaultPosition, [750,-1],
				wxMINIMIZE_BOX|wxCAPTION|wxSYSTEM_MENU|wxSTAY_ON_TOP);

  $data->po->set(e_mu=>1, e_bkg=>0, e_pre=>0, e_post=>0,
		 e_norm=>0, e_der=>0, e_sec=>0, e_markers=>0,
		 e_i0 => 0, e_signal => 0);

  my $hbox  = Wx::BoxSizer->new( wxHORIZONTAL );

  my $leftpane = Wx::Panel->new($this, -1, wxDefaultPosition, wxDefaultSize);
  my $left = Wx::BoxSizer->new( wxVERTICAL );
  $hbox->Add($leftpane, 0, wxGROW|wxALL, 0);

  $this->{left} = $left;
  ## the ln checkbox goes below the column selection widget, but if
  ## refered to in the columns method, so I need to define it here.
  ## it will be placed in the other_parameters method
  $this->{ln}     = Wx::CheckBox->new($leftpane, -1, 'Natural log');
  $this->{energy} = Wx::TextCtrl->new($leftpane, -1, q{}, wxDefaultPosition, [250,-1], wxTE_READONLY);
  $this->{mue}    = Wx::TextCtrl->new($leftpane, -1, q{}, wxDefaultPosition, [250,-1], wxTE_READONLY);
  $this->columns($leftpane, $data);
  $this->other_parameters($leftpane, $data);
  $this->strings($leftpane, $data);



  my $buttons = Wx::BoxSizer->new( wxHORIZONTAL );
  $this->{ok} = Wx::Button->new($leftpane, wxID_OK, "Import", wxDefaultPosition, wxDefaultSize, 0, );
  $buttons -> Add($this->{ok}, 1, wxGROW|wxALL, 5);
  $this->{cancel} = Wx::Button->new($leftpane, wxID_CANCEL, "Cancel", wxDefaultPosition, wxDefaultSize);
  $buttons -> Add($this->{cancel}, 1, wxGROW|wxALL, 5);
  $left -> Add($buttons, 0, wxGROW|wxALL, 5);



  my $rightpane = Wx::Panel->new($this, -1, wxDefaultPosition, [-1,-1]);
  my $right = Wx::BoxSizer->new( wxVERTICAL );
  $hbox->Add($rightpane, 1, wxGROW|wxALL, 0);

  $this->{contents} = Wx::TextCtrl->new($rightpane, -1, q{}, wxDefaultPosition, [550,450],
  					wxTE_MULTILINE|wxTE_RICH2|wxTE_DONTWRAP|wxALWAYS_SHOW_SB);
  $this->{contents} -> SetFont( Wx::Font->new( $contents_font_size, wxTELETYPE, wxNORMAL, wxNORMAL, 0, "" ) );
  $right -> Add($this->{contents}, 1, wxGROW|wxALL, 5);
  $this->{contents}->LoadFile($data->file);

  $leftpane  -> SetSizerAndFit($left);
  $rightpane -> SetSizerAndFit($right);
  $this      -> SetSizerAndFit($hbox);
  return $this;
};

sub columns {
  my ($this, $parent, $data) = @_;
  $data -> _update('data');
  $this->{ln}->SetValue($data->ln);
  my $numerator_string   = ($data->ln) ? $data->i0_string     : $data->signal_string;
  my $denominator_string = ($data->ln) ? $data->signal_string : $data->io_string;

  my $column_string = Ifeffit::get_string('column_label');
  my @cols = split(" ", $column_string);

  my $columnbox      = Wx::StaticBox->new($parent, -1, 'Columns', wxDefaultPosition, wxDefaultSize);
  my $columnboxsizer = Wx::StaticBoxSizer->new( $columnbox, wxVERTICAL );
  $this->{left}     -> Add($columnboxsizer, 0, wxALL|wxGROW, 0);

  my $gbs = Wx::GridBagSizer->new( 3, 3 );

  my $label = Wx::StaticText->new($parent, -1, 'Energy');
  $gbs -> Add($label, Wx::GBPosition->new(1,0));
  $label    = Wx::StaticText->new($parent, -1, 'Numerator');
  $gbs -> Add($label, Wx::GBPosition->new(2,0));
  $label    = Wx::StaticText->new($parent, -1, 'Denominator');
  $gbs -> Add($label, Wx::GBPosition->new(3,0));

  my @energy; $#energy = $#cols+1;
  my @numer;  $#numer  = $#cols+1;
  my @denom;  $#denom  = $#cols+1;

  my $count = 1;
  my @args = (wxDefaultPosition, wxDefaultSize, wxRB_GROUP);
  foreach my $c (@cols) {
    my $i = $count;
    $label    = Wx::StaticText->new($parent, -1, $c);
    $gbs -> Add($label, Wx::GBPosition->new(0,$count));

    my $radio = Wx::RadioButton->new($parent, -1, q{}, @args);
    $gbs -> Add($radio, Wx::GBPosition->new(1,$count));
    EVT_RADIOBUTTON($parent, $radio, sub{OnEnergyClick(@_, $data, $i)});

    my $ncheck = Wx::CheckBox->new($parent, -1, q{});
    $gbs -> Add($ncheck, Wx::GBPosition->new(2,$count));
    EVT_CHECKBOX($parent, $ncheck, sub{OnNumerClick(@_, $this, $data, $i, \@numer)});
    if ($numerator_string =~ m{\b$c\b}) {
      $numer[$i] = 1;
      $ncheck->SetValue(1);
    };

    my $dcheck = Wx::CheckBox->new($parent, -1, q{});
    $gbs -> Add($dcheck, Wx::GBPosition->new(3,$count));
    EVT_CHECKBOX($parent, $dcheck, sub{OnDenomClick(@_, $this, $data, $i, \@denom)});
    if ($denominator_string =~ m{\b$c\b}) {
      $denom[$i] = 1;
      $dcheck->SetValue(1);
    };

    @args = ();
    ++$count;
  };

  $this->display_plot($data) if $data->xmu_string;
  $columnboxsizer -> Add($gbs, 0, wxALL, 5);
  return $this;
};


sub other_parameters {
  my ($this, $parent, $data) = @_;

  my $others = Wx::BoxSizer->new( wxHORIZONTAL );
  $others -> Add($this->{ln}, 0, wxGROW|wxALL, 5);
  EVT_CHECKBOX($parent, $this->{ln}, sub{OnLnClick(@_, $this, $data)});

  $this->{each} = Wx::CheckBox->new($parent, -1, 'Save each channel as a group');
  $others -> Add($this->{each}, 0, wxGROW|wxALL, 5);
  $this->{each}->Enable(0);

  $this->{left}->Add($others, 0, wxGROW|wxALL, 0);
  return $this;
};

sub strings {
  my ($this, $parent, $data) = @_;

  my $gbs = Wx::GridBagSizer->new( 5, 5 );

  $gbs -> Add(Wx::StaticText->new($parent, -1, 'Energy'), Wx::GBPosition->new(0,0));
  $gbs -> Add($this->{energy},                            Wx::GBPosition->new(0,1));
  $this->{energy} -> SetValue($data->energy_string);

  $gbs -> Add(Wx::StaticText->new($parent, -1, "$MU(E)"), Wx::GBPosition->new(1,0));
  $gbs -> Add($this->{mue},                               Wx::GBPosition->new(1,1));
  $this->{mue} -> SetValue($data->xmu_string);

  $this->{left}->Add($gbs, 0, wxGROW|wxALL, 5);

  return $this;
};

sub OnLnClick {
  my ($parent, $event, $this, $data) = @_;
  $data->ln($event->IsChecked);
  $this->display_plot($data);
};

sub OnEnergyClick {
  my ($parent, $event, $data, $i) = @_;
  $data->energy('$'.$i);
};

sub OnNumerClick {
  my ($parent, $event, $this, $data, $i, $aref) = @_;
  $aref->[$i] = $event->IsChecked;
  my $string = q{};
  foreach my $count (1 .. $#$aref) {
    $string .= '$'.$count.'+' if $aref->[$count];
  };
  chop $string;
  #print "numerator is ", $string, $/;
  $string = "1" if not $string;
  $data -> numerator($string);
  $this -> display_plot($data);
};

sub OnDenomClick {
  my ($parent, $event, $this, $data, $i, $aref) = @_;
  $aref->[$i] = $event->IsChecked;
  my $string = q{};
  foreach my $count (1 .. $#$aref) {
    $string .= '$'.$count.'+' if $aref->[$count];
  };
  chop $string;
  #print "denomintor is ", $string, $/;
  $string = "1" if not $string;
  $data -> denominator($string);
  $this -> display_plot($data);
};

sub display_plot {
  my ($this, $data) = @_;
  $data -> _update('normalize');
  $this->{energy} -> SetValue($data->energy_string);
  $this->{mue}    -> SetValue($data->xmu_string);
  my @energy = $data->get_array('energy');
  my ($emin, $emax) = minmax(@energy);
  $data -> po -> set(emin=>$emin, emax=>$emax);
  $data -> po -> start_plot;
  $data -> plot('e');
};

sub ShouldPreventAppExit {
  0
};

1;