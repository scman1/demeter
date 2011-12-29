package Demeter::UI::Athena;

use Demeter qw(:analysis);
#use Demeter::UI::Wx::DFrame;
use Demeter::UI::Wx::MRU;
use Demeter::UI::Wx::SpecialCharacters qw(:all);
use Demeter::UI::Athena::IO;
use Demeter::UI::Athena::Group;
use Demeter::UI::Athena::TextBuffer;
use Demeter::UI::Athena::Replot;
use Demeter::UI::Athena::GroupList;

use Demeter::UI::Artemis::Buffer;
use Demeter::UI::Artemis::ShowText;
use Demeter::UI::Athena::Cursor;
use Demeter::UI::Athena::Status;
use Demeter::UI::Artemis::DND::PlotListDrag;

use vars qw($demeter $buffer $plotbuffer);

use Cwd;
use File::Basename;
use File::Copy;
use File::Path;
use File::Spec;
use List::Util qw(min);
use List::MoreUtils qw(any);
use Time::HiRes qw(usleep);
use Readonly;
Readonly my $FOCUS_UP	       => Wx::NewId();
Readonly my $FOCUS_DOWN	       => Wx::NewId();
Readonly my $MOVE_UP	       => Wx::NewId();
Readonly my $MOVE_DOWN	       => Wx::NewId();
Readonly my $EPSI	       => 0.01;
Readonly my $AUTOSAVE_FILE     => 'Athena.autosave';

use Scalar::Util qw{looks_like_number};

use Wx qw(:everything);
use Wx::Event qw(EVT_MENU EVT_CLOSE EVT_TOOL_ENTER EVT_CHECKBOX EVT_BUTTON
		 EVT_ENTER_WINDOW EVT_LEAVE_WINDOW
		 EVT_RIGHT_UP EVT_LISTBOX EVT_RADIOBOX EVT_LISTBOX_DCLICK
		 EVT_CHOICEBOOK_PAGE_CHANGED EVT_CHOICEBOOK_PAGE_CHANGING
		 EVT_RIGHT_DOWN EVT_LEFT_DOWN EVT_CHECKLISTBOX
	       );
use base 'Wx::App';

use Wx::Perl::Carp qw(verbose);
$SIG{__WARN__} = sub {Wx::Perl::Carp::warn($_[0])};
$SIG{__DIE__}  = sub {Wx::Perl::Carp::warn($_[0])};
#Demeter->meta->add_method( 'confess' => \&Wx::Perl::Carp::warn );
#Demeter->meta->add_method( 'croak'   => \&Wx::Perl::Carp::warn );


sub identify_self {
  my @caller = caller;
  return dirname($caller[1]);
};
use vars qw($athena_base $icon $noautosave %frames);
$athena_base = identify_self();
$noautosave = 0;		# set this to skip autosave, see Demeter::UI::Artemis::Import::_feffit

sub OnInit {
  my ($app) = @_;
  local $|=1;
  #print DateTime->now, "  Initializing Demeter ...\n";
  $demeter = Demeter->new;
  $demeter->set_mode(ifeffit=>1, screen=>0);
  $demeter->mo->silently_ignore_unplottable(1);
  $demeter -> mo -> ui('Wx');
  $demeter -> mo -> identity('Athena');
  $demeter -> mo -> iwd(cwd);

  #print DateTime->now,  "  Reading configuration files ...\n";
  #my $conffile = File::Spec->catfile(dirname($INC{'Demeter/UI/Athena.pm'}), 'Athena', 'share', "athena.demeter_conf");
  #$demeter -> co -> read_config($conffile);
  #$demeter -> co -> read_ini('athena');
  $demeter -> plot_with($demeter->co->default(qw(plot plotwith)));
  my $old_cwd = File::Spec->catfile($demeter->dot_folder, "athena.cwd");
  if (-r $old_cwd) {
    my $yaml = YAML::Tiny::LoadFile($old_cwd);
    chdir($yaml->{cwd});
  };

  ## -------- create a new frame and set icon
  #print DateTime->now,  "  Making main frame ...\n";
  $app->{main} = Wx::Frame->new(undef, -1, 'Athena [XAS data processing]', wxDefaultPosition, wxDefaultSize,);
  #$app->{main} = Demeter::UI::Wx::DFrame->new(undef, -1, 'Athena [XAS data processing]', wxDefaultPosition, wxDefaultSize,);
  my $iconfile = File::Spec->catfile(dirname($INC{'Demeter/UI/Athena.pm'}), 'Athena', 'icons', "athena.png");
  $icon = Wx::Icon->new( $iconfile, wxBITMAP_TYPE_ANY );
  $app->{main} -> SetIcon($icon);
  EVT_CLOSE($app->{main}, sub{$app->on_close($_[1])});

  ## -------- Set up menubar
  #print DateTime->now,  "  Making menubar and status bar...\n";
  $app -> menubar;
  $app -> set_mru();

  ## -------- status bar
  $app->{main}->{statusbar} = $app->{main}->CreateStatusBar;

  ## -------- the business part of the window
  my $hbox = Wx::BoxSizer->new( wxHORIZONTAL );
  #print DateTime->now,  "  Making main window ...\n";
  $app -> main_window($hbox);
  #print DateTime->now,  "  Making side bar ...\n";
  $app -> side_bar($hbox);

  my $accelerator = Wx::AcceleratorTable->new(
   					      [wxACCEL_CTRL, 106, $FOCUS_UP],
   					      [wxACCEL_CTRL, 107, $FOCUS_DOWN],
   					      [wxACCEL_ALT,  106, $MOVE_UP],
   					      [wxACCEL_ALT,  107, $MOVE_DOWN],
   					     );
  $app->{main}->SetAcceleratorTable( $accelerator );



  ## -------- "global" parameters
  #print DateTime->now,  "  Finishing ...\n";
  $app->{lastplot} = [q{}, q{single}];
  $app->{selected} = -1;
  $app->{modified} = 0;
  $app->{main}->{currentproject} = q{};
  $app->{main}->{showing} = q{};
  $app->{constraining_spline_parameters}=0;
  $app->{selecting_data_group}=0;

  ## -------- text buffers for various TextEntryDialogs
  $app->{rename_buffer}  = [];
  $app->{rename_pointer} = -1;
  $app->{regexp_buffer}  = [];
  $app->{regexp_pointer} = -1;
  $app->{style_buffer}   = [];
  $app->{style_pointer}  = -1;

  ## -------- a few more top-level widget-y things
  $app->{main}->{Status} = Demeter::UI::Athena::Status->new($app->{main});
  $app->{main}->{Status}->SetTitle("Athena [Status Buffer]");
  $app->{Buffer} = Demeter::UI::Artemis::Buffer->new($app->{main});
  $app->{Buffer}->SetTitle("Athena [Ifeffit \& Plot Buffer]");

  $demeter->set_mode(callback     => \&ifeffit_buffer,
		     plotcallback => ($demeter->mo->template_plot eq 'pgplot') ? \&ifeffit_buffer : \&plot_buffer,
		     feedback     => \&feedback,
		    );

  $app->{main} -> SetSizerAndFit($hbox);
  $app->{main} ->{return}->Hide;
  #$app->{main} -> SetSize(600,800);
  $app->{main} -> Show( 1 );
  $app->{main} -> Refresh;
  $app->{main} -> Update;
  $app->{main} -> status("Welcome to Athena (" . $demeter->identify . ")");
  $app->OnGroupSelect(q{}, $app->{main}->{list}->GetSelection, 0);
  1;
};

sub process_argv {
  my ($app, @args) = @_;
  if (-r File::Spec->catfile($demeter->stash_folder, $AUTOSAVE_FILE)) {
    my $yesno = Wx::MessageDialog->new($app->{main},
  				       "Athena found an autosave file.  Would you like to import it?",
  				       "Import autosave?",
  				       wxYES_NO|wxYES_DEFAULT|wxICON_QUESTION);
    my $result = $yesno->ShowModal;
    if ($result == wxID_YES) {
      $app->Import(File::Spec->catfile($demeter->stash_folder, $AUTOSAVE_FILE));
    };
    $app->Clear;
    #unlink File::Spec->catfile($demeter->stash_folder, $AUTOSAVE_FILE);
    my $old_cwd = File::Spec->catfile($demeter->dot_folder, "athena.cwd");
    if (-r $old_cwd) {
      my $yaml = YAML::Tiny::LoadFile($old_cwd);
      chdir($yaml->{cwd});
    };
    return;
  };
  foreach my $a (@args) {
    if ($a =~ m{\A-(\d+)\z}) {
      my @list = $demeter->get_mru_list('xasdata');
      my $i = $1-1;
      #print  $list[$i]->[0], $/;
      $app->Import($list[$i]->[0]);
    } elsif (-r $a) {
      $app -> Import($a);
    } elsif (-r File::Spec->catfile($demeter->mo->iwd, $a)) {
      $app->Import(File::Spec->catfile($demeter->mo->iwd, $a));
    }; # switches?
  };
};

sub ifeffit_buffer {
  my ($text) = @_;
  #return if not defined($::app->{Buffer});
  foreach my $line (split(/\n/, $text)) {
    my ($was, $is) = $::app->{Buffer}->insert('ifeffit', $line);
    my $color = ($line =~ m{\A\#}) ? 'comment' : 'normal';
    $::app->{Buffer}->color('ifeffit', $was, $is, $color);
    $::app->{Buffer}->insert('ifeffit', $/)
  };
};
sub plot_buffer {
  my ($text) = @_;
  foreach my $line (split(/\n/, $text)) {
    my ($was, $is) = $::app->{Buffer}->insert('plot', $line);
    my $color = ($line =~ m{\A\#}) ? 'comment'
      : ($demeter->mo->template_plot eq 'singlefile') ? 'singlefile'
	:'normal';

    $::app->{Buffer}->color('plot', $was, $is, $color);
    $::app->{Buffer}->insert('plot', $/)
  };
};
sub feedback {
  my ($text) = @_;
  my ($was, $is) = $::app->{Buffer}->insert('ifeffit', $text);
  my $color = ($text =~ m{\A\s*\*}) ? 'warning' : 'feedback';
  $::app->{Buffer}->color('ifeffit', $was, $is, $color);
};


sub mouseover {
  my ($app, $widget, $text) = @_;
  return if not $demeter->co->default("athena", "hints");
  my $sb = $app->{main}->GetStatusBar;
  EVT_ENTER_WINDOW($widget, sub{$sb->PushStatusText($text); $_[1]->Skip});
  EVT_LEAVE_WINDOW($widget, sub{$sb->PopStatusText if ($sb->GetStatusText eq $text); $_[1]->Skip});
};


sub on_close {
  my ($app, $event) = @_;
  if ($app->{modified}) {
    ## offer to save project....
    my $yesno = Wx::MessageDialog->new($app->{main},
				       "Save this project before exiting?",
				       "Save project?",
				       wxYES_NO|wxCANCEL|wxYES_DEFAULT|wxICON_QUESTION);
    my $result = $yesno->ShowModal;
    if ($result == wxID_CANCEL) {
      $app->{main}->status("Not exiting Athena after all.");
      $event->Veto  if defined $event;
      return 0;
    };
    $app -> Export('all', $app->{main}->{currentproject}) if $result == wxID_YES;
  };

  unlink File::Spec->catfile($demeter->stash_folder, $AUTOSAVE_FILE);
  my $persist = File::Spec->catfile($demeter->dot_folder, "athena.cwd");
  YAML::Tiny::DumpFile($persist, {cwd=>cwd . Demeter->slash});
  $demeter->mo->destroy_all;
  $event->Skip(1) if defined $event;
  return 1;
};
sub on_about {
  my ($app) = @_;

  my $info = Wx::AboutDialogInfo->new;

  $info->SetName( 'Athena' );
  #$info->SetVersion( $demeter->version );
  $info->SetDescription( "XAS Data Processing" );
  $info->SetCopyright( $demeter->identify . "\nusing Ifeffit " . Ifeffit::get_string('&build'));
  $info->SetWebSite( 'http://cars9.uchicago.edu/iffwiki/Demeter', 'The Demeter web site' );
  #$info->SetDevelopers( ["Bruce Ravel <bravel\@bnl.gov>\n",
  #			 "Ifeffit is copyright $COPYRIGHT 1992-2012 Matt Newville"
  #			] );
  $info->SetLicense( $demeter->slurp(File::Spec->catfile($athena_base, 'Athena', 'share', "GPL.dem")) );

  Wx::AboutBox( $info );
}

sub is_empty {
  my ($app) = @_;
  return not $app->{main}->{list}->GetCount;
};

sub current_index {
  my ($app) = @_;
  return $app->{main}->{list}->GetSelection;
};
sub current_data {
  my ($app) = @_;
  return $demeter->dd if not defined $app->{main}->{list};
  return $demeter->dd if not $app->{main}->{list}->GetCount;
  return $app->{main}->{list}->GetIndexedData($app->{main}->{list}->GetSelection);
};

Readonly my $REPORT_ALL        => Wx::NewId();
Readonly my $REPORT_MARKED     => Wx::NewId();
Readonly my $XFIT              => Wx::NewId();
Readonly my $FPATH             => Wx::NewId();

Readonly my $SAVE_MARKED       => Wx::NewId();
Readonly my $SAVE_MUE	       => Wx::NewId();
Readonly my $SAVE_NORM	       => Wx::NewId();
Readonly my $SAVE_CHIK	       => Wx::NewId();
Readonly my $SAVE_CHIR	       => Wx::NewId();
Readonly my $SAVE_CHIQ	       => Wx::NewId();

Readonly my $EACH_MUE	       => Wx::NewId();
Readonly my $EACH_NORM	       => Wx::NewId();
Readonly my $EACH_CHIK	       => Wx::NewId();
Readonly my $EACH_CHIR	       => Wx::NewId();
Readonly my $EACH_CHIQ	       => Wx::NewId();

Readonly my $MARKED_XMU	       => Wx::NewId();
Readonly my $MARKED_NORM       => Wx::NewId();
Readonly my $MARKED_DER	       => Wx::NewId();
Readonly my $MARKED_NDER       => Wx::NewId();
Readonly my $MARKED_SEC	       => Wx::NewId();
Readonly my $MARKED_NSEC       => Wx::NewId();
Readonly my $MARKED_CHI	       => Wx::NewId();
Readonly my $MARKED_CHIK       => Wx::NewId();
Readonly my $MARKED_CHIK2      => Wx::NewId();
Readonly my $MARKED_CHIK3      => Wx::NewId();
Readonly my $MARKED_RMAG       => Wx::NewId();
Readonly my $MARKED_RRE	       => Wx::NewId();
Readonly my $MARKED_RIM	       => Wx::NewId();
Readonly my $MARKED_RPHA       => Wx::NewId();
Readonly my $MARKED_RDPHA      => Wx::NewId();
Readonly my $MARKED_QMAG       => Wx::NewId();
Readonly my $MARKED_QRE	       => Wx::NewId();
Readonly my $MARKED_QIM	       => Wx::NewId();
Readonly my $MARKED_QPHA       => Wx::NewId();

Readonly my $CLEAR_PROJECT     => Wx::NewId();

Readonly my $RENAME	       => Wx::NewId();
Readonly my $COPY	       => Wx::NewId();
#Readonly my $COPY_SERIES       => Wx::NewId();
Readonly my $REMOVE	       => Wx::NewId();
Readonly my $REMOVE_MARKED     => Wx::NewId();
Readonly my $DATA_YAML	       => Wx::NewId();
Readonly my $DATA_TEXT	       => Wx::NewId();
Readonly my $CHANGE_DATATYPE   => Wx::NewId();

Readonly my $VALUES_ALL	       => Wx::NewId();
Readonly my $VALUES_MARKED     => Wx::NewId();
Readonly my $SHOW_REFERENCE    => Wx::NewId();
Readonly my $TIE_REFERENCE     => Wx::NewId();

Readonly my $FREEZE_TOGGLE     => Wx::NewId();
Readonly my $FREEZE_ALL	       => Wx::NewId();
Readonly my $UNFREEZE_ALL      => Wx::NewId();
Readonly my $FREEZE_MARKED     => Wx::NewId();
Readonly my $UNFREEZE_MARKED   => Wx::NewId();
Readonly my $FREEZE_REGEX      => Wx::NewId();
Readonly my $UNFREEZE_REGEX    => Wx::NewId();
Readonly my $FREEZE_TOGGLE_ALL => Wx::NewId();

Readonly my $ZOOM	       => Wx::NewId();
Readonly my $UNZOOM	       => Wx::NewId();
Readonly my $CURSOR	       => Wx::NewId();
Readonly my $PLOT_QUAD	       => Wx::NewId();
Readonly my $PLOT_IOSIG	       => Wx::NewId();
Readonly my $PLOT_K123	       => Wx::NewId();
Readonly my $PLOT_R123	       => Wx::NewId();
Readonly my $PLOT_E00          => Wx::NewId();
Readonly my $PLOT_I0MARKED     => Wx::NewId();
Readonly my $PLOT_STDDEV       => Wx::NewId();
Readonly my $PLOT_VARIENCE     => Wx::NewId();
Readonly my $TERM_1            => Wx::NewId();
Readonly my $TERM_2            => Wx::NewId();
Readonly my $TERM_3            => Wx::NewId();
Readonly my $TERM_4            => Wx::NewId();

Readonly my $SHOW_BUFFER       => Wx::NewId();
Readonly my $PLOT_YAML	       => Wx::NewId();
Readonly my $LCF_YAML	       => Wx::NewId();
Readonly my $PCA_YAML	       => Wx::NewId();
Readonly my $PEAK_YAML	       => Wx::NewId();
Readonly my $STYLE_YAML	       => Wx::NewId();
Readonly my $INDIC_YAML	       => Wx::NewId();
Readonly my $MODE_STATUS       => Wx::NewId();
Readonly my $PERL_MODULES      => Wx::NewId();
Readonly my $STATUS	       => Wx::NewId();
Readonly my $IFEFFIT_STRINGS   => Wx::NewId();
Readonly my $IFEFFIT_SCALARS   => Wx::NewId();
Readonly my $IFEFFIT_GROUPS    => Wx::NewId();
Readonly my $IFEFFIT_ARRAYS    => Wx::NewId();
Readonly my $IFEFFIT_MEMORY    => Wx::NewId();

Readonly my $MARK_ALL	       => Wx::NewId();
Readonly my $MARK_NONE	       => Wx::NewId();
Readonly my $MARK_INVERT       => Wx::NewId();
Readonly my $MARK_TOGGLE       => Wx::NewId();
Readonly my $MARK_REGEXP       => Wx::NewId();
Readonly my $UNMARK_REGEXP     => Wx::NewId();

Readonly my $MERGE_MUE	       => Wx::NewId();
Readonly my $MERGE_NORM	       => Wx::NewId();
Readonly my $MERGE_CHI	       => Wx::NewId();
Readonly my $MERGE_IMP	       => Wx::NewId();
Readonly my $MERGE_NOISE       => Wx::NewId();
Readonly my $MERGE_STEP        => Wx::NewId();

Readonly my $DOCUMENT	       => Wx::NewId();
Readonly my $DEMO	       => Wx::NewId();

sub menubar {
  my ($app) = @_;
  my $bar        = Wx::MenuBar->new;
  $app->{main}->{mrumenu} = Wx::Menu->new;
  my $filemenu   = Wx::Menu->new;
  $filemenu->Append(wxID_OPEN,  "Import data\tCtrl+o", "Import data from a data or project file" );
  $filemenu->AppendSubMenu($app->{main}->{mrumenu}, "Recent files", "This submenu contains a list of recently used files" );
  $filemenu->AppendSeparator;
  $filemenu->Append(wxID_SAVE,    "Save project\tCtrl+s", "Save an Athena project file" );
  $filemenu->Append(wxID_SAVEAS,  "Save project as...", "Save an Athena project file as..." );
  $filemenu->Append($SAVE_MARKED, "Save marked groups as a project ...", "Save marked groups as an Athena project file ..." );
  $filemenu->AppendSeparator;

  my $exportmenu   = Wx::Menu->new;
  $exportmenu->Append($REPORT_ALL,    "Excel report on all groups",    "Write an Excel report on the parameter values of all data groups" );
  $exportmenu->Append($REPORT_MARKED, "Excel report on marked groups", "Write an Excel report on the parameter values of the marked data groups" );
  $exportmenu->AppendSeparator;
  $exportmenu->Append($FPATH,         "Empirical standard",            "Write a file containing an empirical standard derived from this group which Artemis can import as a fitting standard" );
  $exportmenu->Append($XFIT,          "XFit file for current group",   "Write a file for the XFit XAS analysis program for the current group" );

  my $savecurrentmenu = Wx::Menu->new;
  $savecurrentmenu->Append($SAVE_MUE,    "$MU(E)",  "Save $MU(E) from the current group" );
  $savecurrentmenu->Append($SAVE_NORM,   "norm(E)", "Save normalized $MU(E) from the current group" );
  $savecurrentmenu->Append($SAVE_CHIK,   "$CHI(k)", "Save $CHI(k) from the current group" );
  $savecurrentmenu->Append($SAVE_CHIR,   "$CHI(R)", "Save $CHI(R) from the current group" );
  $savecurrentmenu->Append($SAVE_CHIQ,   "$CHI(q)", "Save $CHI(q) from the current group" );

  my $savemarkedmenu = Wx::Menu->new;
  $savemarkedmenu->Append($MARKED_XMU,   "$MU(E)",          "Save marked groups as $MU(E) to a column data file");
  $savemarkedmenu->Append($MARKED_NORM,  "norm(E)",         "Save marked groups as norm(E) to a column data file");
  $savemarkedmenu->Append($MARKED_DER,   "deriv($MU(E))",   "Save marked groups as deriv($MU(E)) to a column data file");
  $savemarkedmenu->Append($MARKED_NDER,  "deriv(norm(E))",  "Save marked groups as deriv(norm(E)) to a column data file");
  $savemarkedmenu->Append($MARKED_SEC,   "second($MU(E))",  "Save marked groups as second($MU(E)) to a column data file");
  $savemarkedmenu->Append($MARKED_NSEC,  "second(norm(E))", "Save marked groups as second(norm(E)) to a column data file");
  $savemarkedmenu->AppendSeparator;
  $savemarkedmenu->Append($MARKED_CHI,   "$CHI(k)",         "Save marked groups as $CHI(k) to a column data file");
  $savemarkedmenu->Append($MARKED_CHIK,  "k$CHI(k)",        "Save marked groups as k$CHI(k) to a column data file");
  $savemarkedmenu->Append($MARKED_CHIK2, "k$TWO$CHI(k)",    "Save marked groups as k$TWO$CHI(k) to a column data file");
  $savemarkedmenu->Append($MARKED_CHIK3, "k$THR$CHI(k)",    "Save marked groups as k$THR$CHI(k) to a column data file");
  $savemarkedmenu->AppendSeparator;
  $savemarkedmenu->Append($MARKED_RMAG,  "|$CHI(R)|",       "Save marked groups as |$CHI(R)| to a column data file");
  $savemarkedmenu->Append($MARKED_RRE,   "Re[$CHI(R)]",     "Save marked groups as Re[$CHI(R)] to a column data file");
  $savemarkedmenu->Append($MARKED_RIM,   "Im[$CHI(R)]",     "Save marked groups as Im[$CHI(R)] to a column data file");
  $savemarkedmenu->Append($MARKED_RPHA,  "Pha[$CHI(R)]",    "Save marked groups as Pha[$CHI(R)] to a column data file");
  $savemarkedmenu->Append($MARKED_RDPHA, "Deriv(Pha[$CHI(R)])", "Save marked groups as the derivative of Pha[$CHI(R)] to a column data file") if ($Demeter::UI::Athena::demeter->co->default("athena", "show_dphase"));
  $savemarkedmenu->AppendSeparator;
  $savemarkedmenu->Append($MARKED_QMAG,  "|$CHI(q)|",       "Save marked groups as |$CHI(q)| to a column data file");
  $savemarkedmenu->Append($MARKED_QRE,   "Re[$CHI(q)]",     "Save marked groups as Re[$CHI(q)] to a column data file");
  $savemarkedmenu->Append($MARKED_QIM,   "Im[$CHI(q)]",     "Save marked groups as Im[$CHI(q)] to a column data file");
  $savemarkedmenu->Append($MARKED_QPHA,  "Pha[$CHI(q)]",    "Save marked groups as Pha[$CHI(q)] to a column data file");

  my $saveeachmenu   = Wx::Menu->new;
  $saveeachmenu->Append($EACH_MUE,    "$MU(E)",  "Save $MU(E) for each marked group" );
  $saveeachmenu->Append($EACH_NORM,   "norm(E)", "Save normalized $MU(E) for each marked group" );
  $saveeachmenu->Append($EACH_CHIK,   "$CHI(k)", "Save $CHI(k) for each marked group" );
  $saveeachmenu->Append($EACH_CHIR,   "$CHI(R)", "Save $CHI(R) for each marked group" );
  $saveeachmenu->Append($EACH_CHIQ,   "$CHI(q)", "Save $CHI(q) for each marked group" );

  $filemenu->AppendSubMenu($savecurrentmenu, "Save current group as ...",     "Save the data in the current group as a column data file" );
  $filemenu->AppendSubMenu($savemarkedmenu,  "Save marked groups as ...",     "Save the data from the marked group as a single column data file" );
  $filemenu->AppendSubMenu($saveeachmenu,    "Save each marked group as ...", "Save the marked groups, each as its own column data file" );
  $filemenu->AppendSubMenu($exportmenu,      "Export ...",                    "Export" );
  $filemenu->AppendSeparator;
  $filemenu->Append($CLEAR_PROJECT, 'Clear project name', 'Clear project name');
  $filemenu->AppendSeparator;
  $filemenu->Append(wxID_CLOSE, "&Close\tCtrl+w" );
  $filemenu->Append(wxID_EXIT,  "E&xit\tCtrl+q" );

  my $monitormenu = Wx::Menu->new;
  my $ifeffitmenu = Wx::Menu->new;
  my $yamlmenu    = Wx::Menu->new;
  my $debugmenu   = Wx::Menu->new;
  $yamlmenu->Append($PLOT_YAML,      "Plot object",            "Show YAML dialog for Plot object" );
  $yamlmenu->Append($STYLE_YAML,     "plot style objects",     "Show YAML dialog for plot style objects" );
  $yamlmenu->Append($INDIC_YAML,     "Indicator objects",      "Show YAML dialog for Indicator objects" );
  $yamlmenu->Append($LCF_YAML,       "LCF object",             "Show YAML dialog for LCF object" );
  $yamlmenu->Append($PCA_YAML,       "PCA object",             "Show YAML dialog for PCA object" );
  $yamlmenu->Append($PEAK_YAML,      "PeakFit object",         "Show YAML dialog for PeakFit object" );
  $debugmenu->Append($MODE_STATUS,   "Show mode status",       "Show mode status dialog" );
  $debugmenu->Append($PERL_MODULES,  "Show perl modules",      "Show perl module versions" );
  $monitormenu->Append($SHOW_BUFFER, "Show command buffer",    'Show the Ifeffit and plotting commands buffer' );
  $monitormenu->Append($STATUS,      "Show status bar buffer", 'Show the buffer containing messages written to the status bars');
  $monitormenu->AppendSeparator;
  $ifeffitmenu->Append($IFEFFIT_STRINGS, "strings",      "Examine all the strings currently defined in Ifeffit");
  $ifeffitmenu->Append($IFEFFIT_SCALARS, "scalars",      "Examine all the scalars currently defined in Ifeffit");
  $ifeffitmenu->Append($IFEFFIT_GROUPS,  "groups",       "Examine all the data groups currently defined in Ifeffit");
  $ifeffitmenu->Append($IFEFFIT_ARRAYS,  "arrays",       "Examine all the arrays currently defined in Ifeffit");
  $monitormenu->AppendSubMenu($ifeffitmenu,  'Query Ifeffit for ...',    'Obtain information from Ifeffit about variables and arrays');
  $monitormenu->Append($IFEFFIT_MEMORY,  "Show Ifeffit's memory use", "Show Ifeffit's memory use and remaining capacity");
  #if ($demeter->co->default("athena", "debug_menus")) {
    $monitormenu->AppendSeparator;
    $monitormenu->AppendSubMenu($yamlmenu,  'Show YAML for ...',    'Display YAMLs of Demeter objects');
    $monitormenu->AppendSubMenu($debugmenu, 'Debug options', 'Display debugging tools');
  #};


  my $groupmenu   = Wx::Menu->new;
  $groupmenu->Append($RENAME, "Rename current group\tShift+Ctrl+l", "Rename the current group");
  $groupmenu->Append($COPY,   "Copy current group\tShift+Ctrl+y",   "Copy the current group");
  $groupmenu->Append($CHANGE_DATATYPE, "Change data type", "Change the data type for the current group or the marked groups");

  $groupmenu->AppendSeparator;
  $groupmenu->Append($VALUES_ALL,    "Set all groups' values to the current",    "Push this groups parameter values onto all other groups.");
  $groupmenu->Append($VALUES_MARKED, "Set marked groups' values to the current", "Push this groups parameter values onto all marked groups.");
  $groupmenu->AppendSeparator;
  #$groupmenu->AppendSubMenu($freezemenu, 'Freeze groups', 'Freeze groups, that is disable their controls such that their parameter values cannot be changed.');
  $groupmenu->Append($DATA_YAML,      "Show structure of current group",                 "Show detailed contents of the current data group");
  $groupmenu->Append($DATA_TEXT,      "Show the text of the current group's data file",  "Show the text of the current data group's data file");
  $groupmenu->AppendSeparator;
  $groupmenu->Append($SHOW_REFERENCE, "Identify reference channel", "Identify the group that shares the data/reference relationship with this group.");
  $groupmenu->Append($TIE_REFERENCE,  "Tie reference channel",  "Tie together two marked groups as data and reference channel.");
  $groupmenu->AppendSeparator;
  $groupmenu->Append($REMOVE,         "Remove current group",   "Remove the current group from this project");
  $groupmenu->Append($REMOVE_MARKED,  "Remove marked groups",   "Remove marked groups from this project");
  $groupmenu->Append(wxID_CLOSE,       "&Close\tCtrl+w" );
  $app->{main}->{groupmenu} = $groupmenu;

  my $freezemenu  = Wx::Menu->new;
  $freezemenu->Append($FREEZE_TOGGLE,     "Toggle this group", "Toggle the frozen state of this group");
  $freezemenu->Append($FREEZE_ALL,        "Freeze all groups", "Freeze all groups");
  $freezemenu->Append($UNFREEZE_ALL,      "Unfreeze all groups", "Unfreeze all groups" );
  $freezemenu->Append($FREEZE_MARKED,     "Freeze marked groups", "Freeze marked groups");
  $freezemenu->Append($UNFREEZE_MARKED,   "Unfreeze marked groups", "Unfreeze marked groups");
  $freezemenu->Append($FREEZE_REGEX,      "Freeze by regex", "Freeze by regex");
  $freezemenu->Append($UNFREEZE_REGEX,    "Unfreeze by regex", "Unfreeze by regex");
  $freezemenu->Append($FREEZE_TOGGLE_ALL, "Toggle frozen state of all groups", "Toggle frozen state of all groups");
  $app->{main}->{freezemenu} = $freezemenu;


  my $plotmenu    = Wx::Menu->new;
  my $currentplotmenu = Wx::Menu->new;
  my $markedplotmenu  = Wx::Menu->new;
  my $mergedplotmenu  = Wx::Menu->new;
  $app->{main}->{currentplotmenu} = $currentplotmenu;
  $app->{main}->{markedplotmenu}  = $markedplotmenu;
  $app->{main}->{mergedplotmenu}  = $mergedplotmenu;
  $currentplotmenu->Append($PLOT_QUAD,       "Quad plot",             "Make a quad plot from the current group" );
  $currentplotmenu->Append($PLOT_IOSIG,      "Data+I0+Signal",        "Plot data, I0, and signal from the current group" );
  $currentplotmenu->Append($PLOT_K123,       "k123 plot",             "Make a k123 plot from the current group" );
  $currentplotmenu->Append($PLOT_R123,       "R123 plot",             "Make an R123 plot from the current group" );
  $markedplotmenu ->Append($PLOT_E00,        "Plot with E0 at E=0",   "Plot each of the marked groups with its edge energy at E=0" );
  $markedplotmenu ->Append($PLOT_I0MARKED,   "Plot I0",               "Plot I0 for each of the marked groups" );
  $mergedplotmenu ->Append($PLOT_STDDEV,     "Plot data + std. dev.", "Plot the merged data along with its standard deviation" );
  $mergedplotmenu ->Append($PLOT_VARIENCE,   "Plot data + variance",  "Plot the merged data along with its scaled variance" );

  if ($demeter->co->default('plot', 'plotwith') eq 'pgplot') {
    $plotmenu->Append($ZOOM,   'Zoom\tCtrl++',   'Zoom in on the latest plot');
    $plotmenu->Append($UNZOOM, 'Unzoom\tCtrl+-', 'Unzoom');
    $plotmenu->Append($CURSOR, 'Cursor\tCtrl+.', 'Show the coordinates of a point on the plot');
    $plotmenu->AppendSeparator;
  };
  $plotmenu->AppendSubMenu($currentplotmenu, "Current group", "Special plot types for the current group");
  $plotmenu->AppendSubMenu($markedplotmenu,  "Marked groups", "Special plot types for the marked groups");
  $plotmenu->AppendSubMenu($mergedplotmenu,  "Merge groups",  "Special plot types for merge data");
  if ($demeter->co->default('plot', 'plotwith') eq 'gnuplot') {
    $plotmenu->AppendSeparator;
    $plotmenu->AppendRadioItem($TERM_1, "Plot to terminal 1", "Plot to terminal 1");
    $plotmenu->AppendRadioItem($TERM_2, "Plot to terminal 2", "Plot to terminal 2");
    $plotmenu->AppendRadioItem($TERM_3, "Plot to terminal 3", "Plot to terminal 3");
    $plotmenu->AppendRadioItem($TERM_4, "Plot to terminal 4", "Plot to terminal 4");
  };
  $app->{main}->{plotmenu} = $plotmenu;

  my $markmenu   = Wx::Menu->new;
  $markmenu->Append($MARK_ALL,      "Mark all\tShift+Ctrl+a",            "Mark all groups" );
  $markmenu->Append($MARK_NONE,     "Clear all marks\tShift+Ctrl+u",     "Clear all marks" );
  $markmenu->Append($MARK_INVERT,   "Invert marks\tShift+Ctrl+i",        "Invert all mark" );
  $markmenu->Append($MARK_TOGGLE,   "Toggle current mark\tShift+Ctrl+t", "Toggle mark of current group" );
  $markmenu->Append($MARK_REGEXP,   "Mark by regexp\tShift+Ctrl+r",      "Mark all groups matching a regular expression" );
  $markmenu->Append($UNMARK_REGEXP, "Unmark by regex\tShift+Ctrl+x",     "Unmark all groups matching a regular expression" );
  $app->{main}->{markmenu} = $markmenu;

  my $mergemenu  = Wx::Menu->new;
  $mergemenu->Append($MERGE_MUE,  "Merge $MU(E)",  "Merge marked data at $MU(E)" );
  $mergemenu->Append($MERGE_NORM, "Merge norm(E)", "Merge marked data at normalized $MU(E)" );
  $mergemenu->Append($MERGE_CHI,  "Merge $CHI(k)", "Merge marked data at $CHI(k)" );
  $mergemenu->AppendSeparator;
  $mergemenu->AppendRadioItem($MERGE_IMP,   "Weight by importance",       "Weight the marked groups by their importance values when merging" );
  $mergemenu->AppendRadioItem($MERGE_NOISE, "Weight by noise in $CHI(k)", "Weight the marked groups by their $CHI(k) noise values when merging" );
  $mergemenu->AppendRadioItem($MERGE_STEP,  "Weight by $MU(E) edge step", "Weight the marked groups the size of the edge step in $MU(E) when merging" );
  $mergemenu->Check($MERGE_IMP,   1) if ($demeter->co->default('merge', 'weightby') eq 'importance');
  $mergemenu->Check($MERGE_NOISE, 1) if ($demeter->co->default('merge', 'weightby') eq 'noise');
  $mergemenu->Check($MERGE_STEP,  1) if ($demeter->co->default('merge', 'weightby') eq 'step');


  my $helpmenu   = Wx::Menu->new;
  $helpmenu->Append($DOCUMENT,  "Document",     "Open the Athena document" );
  $helpmenu->Append($DEMO,      "Demo project", "Open a demo project" );
  $helpmenu->AppendSeparator;
  $helpmenu->Append(wxID_ABOUT, "&About Athena" );

  $bar->Append( $filemenu,    "&File" );
  $bar->Append( $groupmenu,   "&Group" );
  $bar->Append( $markmenu,    "&Mark" );
  $bar->Append( $plotmenu,    "&Plot" );
  #$bar->Append( $freezemenu,  "Free&ze" );
  $bar->Append( $mergemenu,   "Me&rge" );
  $bar->Append( $monitormenu, "M&onitor" );
  $bar->Append( $helpmenu,    "&Help" );
  $app->{main}->SetMenuBar( $bar );

  $exportmenu     -> Enable($_,0) foreach ($XFIT);
  $plotmenu       -> Enable($_,0) foreach ($ZOOM, $UNZOOM, $CURSOR);
  $mergedplotmenu -> Enable($_,0) foreach ($PLOT_STDDEV, $PLOT_VARIENCE);
  $freezemenu     -> Enable($_,0) foreach ($FREEZE_TOGGLE, $FREEZE_ALL, $UNFREEZE_ALL,
					   $FREEZE_MARKED, $UNFREEZE_MARKED,
					   $FREEZE_REGEX, $UNFREEZE_REGEX,
					   $FREEZE_TOGGLE_ALL);
  $helpmenu       -> Enable($_,0) foreach ($DOCUMENT, $DEMO);

  EVT_MENU($app->{main}, -1, sub{my ($frame,  $event) = @_; OnMenuClick($frame,  $event, $app)} );
  return $app;
};

sub set_mru {
  my ($app) = @_;

  foreach my $i (0 .. $app->{main}->{mrumenu}->GetMenuItemCount-1) {
    $app->{main}->{mrumenu}->Delete($app->{main}->{mrumenu}->FindItemByPosition(0));
  };

  my @list = $demeter->get_mru_list('xasdata');
  foreach my $f (@list) {
    ##print ">> ", join("|", @$f),  "  \n";
    $app->{main}->{mrumenu}->Append(-1, $f->[0]);
  };
};

sub set_mergedplot {
  my ($app, $bool) = @_;
  $app->{main}->{mergedplotmenu} ->Enable($_,$bool) foreach ($PLOT_STDDEV, $PLOT_VARIENCE);
};

sub OnMenuClick {
  my ($self, $event, $app) = @_;
  my $id = $event->GetId;
  my $mru = $app->{main}->{mrumenu}->GetLabel($id);
  $mru =~ s{__}{_}g; 		# wtf!?!?!?

 SWITCH: {
    ($mru) and do {
      $app->{main}->status("$mru does not exist"), return if (not -e $mru);
      $app->{main}->status("cannot read $mru"),    return if (not -r $mru);
      $app -> Import($mru);
      last SWITCH;
    };
    ($id == wxID_ABOUT) and do {
      &on_about;
      last SWITCH;
    };
    ($id == $CLEAR_PROJECT) and do {
      $app->Clear;
      last SWITCH;
    };

    ($id == wxID_CLOSE) and do {
      $app->Remove('all');
      last SWITCH;
    };
    ($id == wxID_EXIT) and do {
      #my $ok = $app->on_close;
      #return if not $ok;
      $self->Close;
      return;
    };
    ($id == wxID_OPEN) and do {
      $app -> Import();
      last SWITCH;
    };
    ($id == wxID_SAVE) and do {
      $app -> Export('all', $app->{main}->{currentproject});
      last SWITCH;
    };
    ($id == wxID_SAVEAS) and do {
      $app -> Export('all');
      last SWITCH;
    };
    ($id == $SAVE_MARKED) and do {
      $app -> Export('marked');
      last SWITCH;
    };

    ($id == $REPORT_ALL) and do {
      last SWITCH if $app->is_empty;
      $app -> Report('all');
      last SWITCH;
    };
    ($id == $REPORT_MARKED) and do {
      last SWITCH if $app->is_empty;
      $app -> Report('marked');
      last SWITCH;
    };
    ($id == $FPATH) and do {
      $app -> FPath;
      last SWITCH;
    };

    (any {$id == $_} ($SAVE_MUE, $SAVE_NORM, $SAVE_CHIK, $SAVE_CHIR, $SAVE_CHIQ)) and do {
      my $how = ($id == $SAVE_MUE)  ? 'mue'
	      : ($id == $SAVE_NORM) ? 'norm'
	      : ($id == $SAVE_CHIK) ? 'chik'
	      : ($id == $SAVE_CHIR) ? 'chir'
	      : ($id == $SAVE_CHIQ) ? 'chiq'
	      :                       '???';
      $app->save_column($how);
      last SWITCH;
    };

    (any {$id == $_} ($MARKED_XMU,  $MARKED_NORM, $MARKED_DER,  $MARKED_NDER,  $MARKED_SEC,
		      $MARKED_NSEC, $MARKED_CHI,  $MARKED_CHIK, $MARKED_CHIK2, $MARKED_CHIK3,
		      $MARKED_RMAG, $MARKED_RRE,  $MARKED_RIM,  $MARKED_RPHA,  $MARKED_RDPHA,
		      $MARKED_QMAG, $MARKED_QRE,  $MARKED_QIM,  $MARKED_QPHA))
      and do {
	my $how = ($id == $MARKED_XMU)   ? "xmu"
	        : ($id == $MARKED_NORM)  ? "norm"
 	        : ($id == $MARKED_DER)   ? "der"
	        : ($id == $MARKED_NDER)  ? "nder"
	        : ($id == $MARKED_SEC)   ? "sec"
	        : ($id == $MARKED_NSEC)  ? "nsec"
	        : ($id == $MARKED_CHI)   ? "chi"
	        : ($id == $MARKED_CHIK)  ? "chik"
	        : ($id == $MARKED_CHIK2) ? "chik2"
	        : ($id == $MARKED_CHIK3) ? "chik3"
	        : ($id == $MARKED_RMAG)  ? "chir_mag"
	        : ($id == $MARKED_RRE)   ? "chir_re"
	        : ($id == $MARKED_RIM)   ? "chir_im"
	        : ($id == $MARKED_RPHA)  ? "chir_pha"
	        : ($id == $MARKED_RDPHA) ? "dph"
	        : ($id == $MARKED_QMAG)  ? "chiq_mag"
	        : ($id == $MARKED_QRE)   ? "chiq_re"
	        : ($id == $MARKED_QIM)   ? "chiq_im"
	        : ($id == $MARKED_QPHA)  ? "chiq_pha"
		:                          '???';
	$app->save_marked($how);
	last SWITCH;
      };

    (any {$id == $_} ($EACH_MUE, $EACH_NORM, $EACH_CHIK, $EACH_CHIR, $EACH_CHIQ)) and do {
      my $how = ($id == $EACH_MUE)  ? 'mue'
	      : ($id == $EACH_NORM) ? 'norm'
	      : ($id == $EACH_CHIK) ? 'chik'
	      : ($id == $EACH_CHIR) ? 'chir'
	      : ($id == $EACH_CHIQ) ? 'chiq'
	      :                       '???';
      $app->save_each($how);
      last SWITCH;
    };

    ## -------- group menu
    ($id == $RENAME) and do {
      $app->Rename;
      last SWITCH;
    };
    ($id == $COPY) and do {
      $app->Copy;
      last SWITCH;
    };
    ($id == $CHANGE_DATATYPE) and do {
      $app->change_datatype;
      last SWITCH;
    };
    ($id == $SHOW_REFERENCE) and do {
      last SWITCH if $app->is_empty;
      $app->{main}->status("The current group is tied to \"" . $app->current_data->reference->name . "\".");
      last SWITCH;
    };
    ($id == $TIE_REFERENCE) and do {
      last SWITCH if $app->is_empty;
      $app->tie_reference;
      last SWITCH;
    };
    ($id == $REMOVE) and do {
      $app->Remove('current');
      last SWITCH;
    };
    ($id == $REMOVE_MARKED) and do {
      $app->Remove('marked');
      last SWITCH;
    };
    ($id == $DATA_YAML) and do {
      last SWITCH if $app->is_empty;
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $app->current_data->serialization, 'Structure of Data object')
	  -> Show;
      last SWITCH;
    };
    ($id == $DATA_TEXT) and do {
      last SWITCH if $app->is_empty;
      if (-e $app->current_data->file) {
	my $dialog = Demeter::UI::Artemis::ShowText
	  -> new($app->{main}, $demeter->slurp($app->current_data->file), 'Text of data file')
	    -> Show;
      } else {
	$app->{main}->status("The current group's data file cannot be found.");
      };
      last SWITCH;
    };

    ## -------- values menu
    ($id == $VALUES_ALL) and do {
      $app->{main}->{Main}->constrain($app, 'all', 'all');
      last SWITCH;
    };
    ($id == $VALUES_MARKED) and do {
      $app->{main}->{Main}->constrain($app, 'all', 'marked');
      last SWITCH;
    };

    ## -------- merge menu
    ($id == $MERGE_MUE) and do {
      $app->merge('e');
      last SWITCH;
    };
    ($id == $MERGE_NORM) and do {
      $app->merge('n');
      last SWITCH;
    };
    ($id == $MERGE_CHI) and do {
      $app->merge('k');
      last SWITCH;
    };
    ($id == $MERGE_IMP) and do {
      $demeter->mo->merge('importance');
      $app->{main}->status("Weighting merges by " . $demeter->mo->merge);
      last SWITCH;
    };
    ($id == $MERGE_NOISE) and do {
      $demeter->mo->merge('noise');
      $app->{main}->status("Weighting merges by " . $demeter->mo->merge);
      last SWITCH;
    };
    ($id == $MERGE_STEP) and do {
      $demeter->mo->merge('step');
      $app->{main}->status("Weighting merges by " . $demeter->mo->merge);
      last SWITCH;
    };

    ## -------- monitor menu
    ($id == $SHOW_BUFFER) and do {
      $app->{Buffer}->Show(1);
      last SWITCH;
    };
    ($id == $STATUS) and do {
      $app->{main}->{Status} -> Show(1);
      last SWITCH;
    };
    ($id == $IFEFFIT_STRINGS) and do {
      $app->show_ifeffit('strings');
      last SWITCH;
    };
    ($id == $IFEFFIT_SCALARS) and do {
      $app->show_ifeffit('scalars');
      last SWITCH;
    };
    ($id == $IFEFFIT_GROUPS) and do {
      $app->show_ifeffit('groups');
      last SWITCH;
    };
    ($id == $IFEFFIT_ARRAYS) and do {
      $app->show_ifeffit('arrays');
      last SWITCH;
    };
    ## -------- debug submenu
    ($id == $PLOT_YAML) and do {
      $app->{main}->{PlotE}->pull_single_values;
      $app->{main}->{PlotK}->pull_single_values;
      $app->{main}->{PlotR}->pull_marked_values;
      $app->{main}->{PlotQ}->pull_marked_values;
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $demeter->po->serialization, 'YAML of Plot object')
	  -> Show;
      last SWITCH;
    };

    ($id == $LCF_YAML) and do {
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $app->{main}->{LCF}->{LCF}->serialization, 'YAML of Plot object')
	  -> Show;
      last SWITCH;
    };
    ($id == $PCA_YAML) and do {
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $app->{main}->{PCA}->{PCA}->serialization, 'YAML of Plot object')
	  -> Show;
      last SWITCH;
    };
    ($id == $PEAK_YAML) and do {
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $app->{main}->{PeakFit}->{PEAK}->serialization, 'YAML of Plot object')
	  -> Show;
      last SWITCH;
    };
    ($id == $STYLE_YAML) and do {
      my $text = q{};
      foreach my $i (0 .. $app->{main}->{Style}->{list}->GetCount-1) {
	$text .= $app->{main}->{Style}->{list}->GetClientData($i)->serialization;
      };
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $text, 'YAML of Style objects')
	  -> Show;
      last SWITCH;
    };
    ($id == $INDIC_YAML) and do {
      my $text = q{};
      foreach my $i (1 .. $Demeter::UI::Athena::Plot::Indicators::nind) {
	$text .= $app->{main}->{Indicators}->{'group'.$i}->serialization if (ref($app->{main}->{Indicators}->{'group'.$i}) =~ m{Indicator});
      };
      my $dialog = Demeter::UI::Artemis::ShowText
	-> new($app->{main}, $text, 'YAML of Indicator objects')
	  -> Show;
      last SWITCH;
    };

    ($id == $PERL_MODULES) and do {
      my $text   = $demeter->module_environment . $demeter -> wx_environment;
      my $dialog = Demeter::UI::Artemis::ShowText->new($app->{main}, $text, 'Perl module versions') -> Show;
      last SWITCH;
    };
    ($id == $MODE_STATUS) and do {
      my $dialog = Demeter::UI::Artemis::ShowText->new($app->{main}, $demeter->mo->report('all'), 'Overview of this instance of Demeter') -> Show;
      last SWITCH;
    };

    ($id == $IFEFFIT_MEMORY) and do {
      $app->heap_check(1);
      last SWITCH;
    };

    ($id == $PLOT_QUAD) and do {
      my $data = $app->current_data;
      if ($app->current_data->datatype ne 'xmu') {
	$app->{main}->status("Cannot plot " . $app->current_data->datatype . " data as a quadplot.", "error");
	return;
      };
      #$app->{main}->{Main}->pull_values($data);
      $data->po->start_plot;
      $app->quadplot($data);
      last SWITCH;
    };
    ($id == $PLOT_IOSIG) and do {
      my $data = $app->current_data;
      my $is_fixed = $data->bkg_fixstep;
      #$app->{main}->{Main}->pull_values($data);
      $app->{main}->{PlotE}->pull_single_values;
      $data->po->set(e_bkg=>0, e_pre=>0, e_post=>0, e_norm=>0, e_der=>0, e_sec=>0);
      $data->po->set(e_mu=>1, e_i0=>1, e_signal=>1);
      return if not $app->preplot('e', $data);
      $data->po->start_plot;
      $data->po->title($app->{main}->{Other}->{title}->GetValue);
      $data->plot('E');
      $data->po->set(e_i0=>0, e_signal=>0);
      $app->{main}->{plottabs}->SetSelection(1) if $app->spacetab;
      $app->{lastplot} = ['E', 'single'];
      $app->postplot($data, $is_fixed);
      last SWITCH;
    };
    ($id == $PLOT_K123) and do {
      my $data = $app->current_data;
      my $is_fixed = $data->bkg_fixstep;
      #$app->{main}->{Main}->pull_values($data);
      $app->{main}->{PlotK}->pull_single_values;
      return if not $app->preplot('k', $data);
      $data->po->start_plot;
      $data->po->title($app->{main}->{Other}->{title}->GetValue);
      $data->plot('k123');
      $app->{main}->{plottabs}->SetSelection(2) if $app->spacetab;
      $app->{lastplot} = ['k', 'single'];
      $app->postplot($data, $is_fixed);
      last SWITCH;
    };
    ($id == $PLOT_R123) and do {
      my $data = $app->current_data;
      my $is_fixed = $data->bkg_fixstep;
      #$app->{main}->{Main}->pull_values($data);
      $app->{main}->{PlotR}->pull_marked_values;
      return if not $app->preplot('r', $data);
      $data->po->start_plot;
      $data->po->title($app->{main}->{Other}->{title}->GetValue);
      $data->plot('R123');
      $app->postplot($data, $is_fixed);
      $app->{main}->{plottabs}->SetSelection(3) if $app->spacetab;
      $app->{lastplot} = ['R', 'single'];
      last SWITCH;
    };
    ($id == $PLOT_STDDEV) and do {
      my $data = $app->current_data;
      last SWITCH if not $data->is_merge;
      my $sp = $data->is_merge;
      $sp = 'e' if ($sp eq 'n');
      #return if not $app->preplot($sp, $data);
      my $which = ($sp eq 'k') ? 'PlotK' : 'PlotE';
      $app->{main}->{$which}->pull_marked_values;
      $data->po->title($app->{main}->{Other}->{title}->GetValue);
      $data->plot('stddev');
      #$app->postplot($data);
      $app->{lastplot} = [$sp, 'single'];
      last SWITCH;
    };
    ($id == $PLOT_VARIENCE) and do {
      my $data = $app->current_data;
      last SWITCH if not $data->is_merge;
      #return if not $app->postplot($data);
      my $sp = $data->is_merge;
      $sp = 'E' if ($sp eq 'n');
      my $which = ($sp eq 'k') ? 'PlotK' : 'PlotE';
      $app->{main}->{$which}->pull_marked_values;
      $data->po->title($app->{main}->{Other}->{title}->GetValue);
      $data->plot('variance');
      #$app->postplot($data);
      $app->{lastplot} = [$sp, 'single'];
      last SWITCH;
    };
    ($id == $PLOT_E00) and do {
      $app->plot_e00;
      last SWITCH;
    };
    ($id == $PLOT_I0MARKED) and do {
      $app->plot_i0_marked;
      last SWITCH;
    };

    ($id == $TERM_1) and do {
      $demeter->po->terminal_number(1);
      last SWITCH;
    };
    ($id == $TERM_2) and do {
      $demeter->po->terminal_number(2);
      last SWITCH;
    };
    ($id == $TERM_3) and do {
      $demeter->po->terminal_number(3);
      last SWITCH;
    };
    ($id == $TERM_4) and do {
      $demeter->po->terminal_number(4);
      last SWITCH;
    };

    ($id == $MARK_ALL) and do {
      $app->mark('all');
      last SWITCH;
    };
    ($id == $MARK_NONE) and do {
      $app->mark('none');
      last SWITCH;
    };
    ($id == $MARK_INVERT) and do {
      $app->mark('invert');
      last SWITCH;
    };
    ($id == $MARK_TOGGLE) and do {
      $app->mark('toggle');
      last SWITCH;
    };
    ($id == $MARK_REGEXP) and do {
      $app->mark('regexp');
      last SWITCH;
    };
    ($id == $UNMARK_REGEXP) and do {
      $app->mark('unmark_regexp');
      last SWITCH;
    };

    ($id == $FOCUS_UP) and do {
      $app->focus_up;
      return;
    };
    ($id == $FOCUS_DOWN) and do {
      $app->focus_down;
      return;
    };
    ($id == $MOVE_UP) and do {
      $app->move_group("up");
      return;
    };
    ($id == $MOVE_DOWN) and do {
      $app->move_group("down");
      return;
    };


    ($id == wxID_ABOUT) and do {
      $app->on_about;
      return;
    };

  };
};


sub show_ifeffit {
  my ($app, $which) = @_;
  $demeter->dispose('show @'.$which);
  $app->{Buffer}->{iffcommands}->ShowPosition($app->{Buffer}->{iffcommands}->GetLastPosition);
  $app->{Buffer}->Show(1);
};

sub main_window {
  my ($app, $hbox) = @_;

  my $viewpanel = Wx::Panel    -> new($app->{main}, -1);
  my $viewbox   = Wx::BoxSizer -> new( wxVERTICAL );
  $hbox        -> Add($viewpanel, 0, wxGROW|wxALL, 0);


  my $topbar = Wx::BoxSizer->new( wxHORIZONTAL );
  $viewbox -> Add($topbar, 0, wxGROW|wxRIGHT, 5);

  $app->{main}->{token}   = Wx::StaticText->new($viewpanel, -1, q{ }, wxDefaultPosition, [10,-1]);
  $app->{main}->{project} = Wx::StaticText->new($viewpanel, -1, q{<untitled>},);
  my $size = Wx::SystemSettings::GetFont(wxSYS_DEFAULT_GUI_FONT)->GetPointSize + 2;
  $app->{main}->{project}->SetFont( Wx::Font->new( $size, wxDEFAULT, wxNORMAL, wxBOLD, 0, "" ) );
  $topbar -> Add($app->{main}->{token},   0, wxTOP|wxBOTTOM|wxLEFT, 5);
  $topbar -> Add($app->{main}->{project}, 0, wxGROW|wxALL, 5);

  $topbar -> Add(1,1,1);

  $app->{main}->{save}   = Wx::Button->new($viewpanel, wxID_SAVE, q{},  wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
  $app->{main}->{all}    = Wx::Button->new($viewpanel, -1,        q{A}, wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
  $app->{main}->{none}   = Wx::Button->new($viewpanel, -1,        q{U}, wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
  $app->{main}->{invert} = Wx::Button->new($viewpanel, -1,        q{I}, wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
  $topbar -> Add($app->{main}->{save},   0, wxGROW|wxTOP|wxBOTTOM, 2);
  $topbar -> Add(Wx::StaticText->new($viewpanel, -1, q{    }), 0, wxGROW|wxTOP|wxBOTTOM, 2);
  $topbar -> Add($app->{main}->{all},    0, wxGROW|wxTOP|wxBOTTOM, 2);
  $topbar -> Add($app->{main}->{none},   0, wxGROW|wxTOP|wxBOTTOM, 2);
  $topbar -> Add($app->{main}->{invert}, 0, wxGROW|wxTOP|wxBOTTOM, 2);
  $app->{main}->{save} -> Enable(0);
  $app->{main}->{save_start_color} = $app->{main}->{save}->GetBackgroundColour;
  $app->EVT_BUTTON($app->{main}->{save},   sub{$app -> Export('all', $app->{main}->{currentproject})});
  $app->EVT_BUTTON($app->{main}->{all},    sub{$app->mark('all')});
  $app->EVT_BUTTON($app->{main}->{none},   sub{$app->mark('none')});
  $app->EVT_BUTTON($app->{main}->{invert}, sub{$app->mark('invert')});
  $app->mouseover($app->{main}->{save},   "One-click-save your project");
  $app->mouseover($app->{main}->{all},    "Mark all groups");
  $app->mouseover($app->{main}->{none},   "Clear all marks");
  $app->mouseover($app->{main}->{invert}, "Invert all marks");



  $app->{main}->{views} = Wx::Choicebook->new($viewpanel, -1);
  $viewbox -> Add($app->{main}->{views}, 0, wxALL, 5);
  #print join("|", $app->{main}->{views}->GetChildren), $/;
  $app->mouseover($app->{main}->{views}->GetChildren, "Change data processing and analysis tools using this menu.");

  foreach my $which ('Main',		  # 0
		     'Calibrate',	  # 1
		     'Align',		  # 2
		     'Rebin',		  # 3
		     'DeglitchTruncate',  # 4
		     'Smooth',		  # 5
		     'ConvoluteNoise',	  # 6
		     'Deconvolute',	  # 7
		     'SelfAbsorption',	  # 8
		     'Series',            # 9
		     # -----------------------
		     'LCF',		  # 11
		     'PCA',		  # 12
		     'PeakFit',		  # 13
		     'LogRatio',	  # 14
		     'Difference',	  # 15
		     # -----------------------
		     'XDI',               # 17
		     'Watcher',           # 18
		     'Journal',		  # 19
		     'PluginRegistry',    # 20
		     'Prefs',		  # 21
		    ) {
    next if (($which eq 'Watcher') and (not Demeter->co->default(qw(athena show_watcher))));
    next if $INC{"Demeter/UI/Athena/$which.pm"};
    require "Demeter/UI/Athena/$which.pm";
    $app->{main}->{$which} = "Demeter::UI::Athena::$which"->new($app->{main}->{views}, $app);
    my $label = eval '$'.'Demeter::UI::Athena::'.$which.'::label';
    $app->{main}->{views} -> AddPage($app->{main}->{$which}, $label, 0);
    next if (not exists $app->{main}->{$which}->{document});
    $app->{main}->{$which}->{document} -> Enable(0);
  };
  $app->{main}->{views}->SetSelection(0);

  $app->{main}->{return}   = Wx::Button->new($viewpanel, -1, 'Return to main window', wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
  $app->EVT_BUTTON($app->{main}->{return},   sub{  $app->{main}->{views}->SetSelection(0); $app->OnGroupSelect(0)});
  $viewbox -> Add($app->{main}->{return}, 0, wxGROW|wxLEFT|wxRIGHT, 5);

  $viewpanel -> SetSizerAndFit($viewbox);

  require Demeter::UI::Athena::Null;
  my $null = Demeter::UI::Athena::Null->new($app->{main}->{views});
  $app->{main}->{views}->InsertPage(10, $null, $Demeter::UI::Athena::Null::label, 0);
  $app->{main}->{views}->InsertPage(16, $null, $Demeter::UI::Athena::Null::label, 0);


  EVT_CHOICEBOOK_PAGE_CHANGED($app->{main}, $app->{main}->{views}, sub{$app->OnGroupSelect(0,0,0);
								       $app->{main}->{return}->Show($app->{main}->{views}->GetSelection)});
  EVT_CHOICEBOOK_PAGE_CHANGING($app->{main}, $app->{main}->{views}, sub{$app->view_changing(@_)});


  return $app;
};

sub side_bar {
  my ($app, $hbox) = @_;

  my $toolpanel = Wx::Panel    -> new($app->{main}, -1);
  my $toolbox   = Wx::BoxSizer -> new( wxVERTICAL );
  $hbox        -> Add($toolpanel, 1, wxGROW|wxALL, 0);

  $app->{main}->{list} = Wx::CheckListBox->new($toolpanel, -1, wxDefaultPosition, wxDefaultSize, [], wxLB_SINGLE|wxLB_NEEDED_SB);
  $app->{main}->{list}->{datalist} = []; # see modifications to CheckBookList at end of this file....
  $toolbox            -> Add($app->{main}->{list}, 1, wxGROW|wxALL, 0);
  EVT_LISTBOX($toolpanel, $app->{main}->{list}, sub{$app->OnGroupSelect(@_,1)});
  EVT_LISTBOX_DCLICK($toolpanel, $app->{main}->{list}, sub{$app->Rename;});
  EVT_RIGHT_DOWN($app->{main}->{list}, sub{OnRightDown(@_)});
  EVT_LEFT_DOWN($app->{main}->{list}, \&OnDrag);
  EVT_CHECKLISTBOX($toolpanel, $app->{main}->{list}, sub{OnMark(@_, $app->{main}->{list})});
  $app->{main}->{list}->SetDropTarget( Demeter::UI::Athena::DropTarget->new( $app->{main}, $app->{main}->{list} ) );
  #print Wx::SystemSettings::GetColour(wxSYS_COLOUR_HIGHLIGHT), $/;
  #$app->{main}->{list}->SetBackgroundColour(Wx::Colour->new($demeter->co->default("athena", "single")));

  my $singlebox = Wx::BoxSizer->new( wxHORIZONTAL );
  my $markedbox = Wx::BoxSizer->new( wxHORIZONTAL );
  $toolbox -> Add($singlebox, 0, wxGROW|wxALL, 0);
  $toolbox -> Add($markedbox, 0, wxGROW|wxALL, 0);
  foreach my $which (qw(E k R q kq)) {

    ## single plot button
    my $key = 'plot_single_'.$which;
    $app->{main}->{$key} = Wx::Button -> new($toolpanel, -1, sprintf("%2.2s",$which), wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
    $app->{main}->{$key}-> SetBackgroundColour( Wx::Colour->new($demeter->co->default("athena", "single")) );
    $singlebox          -> Add($app->{main}->{$key}, 1, wxALL, 1);
    EVT_BUTTON($app->{main}, $app->{main}->{$key}, sub{$app->plot(@_, $which, 'single')});
    $app->mouseover($app->{main}->{$key}, "Plot the current group in $which");
    next if ($which eq 'kq');

    ## marked plot buttons
    $key    = 'plot_marked_'.$which;
    $app->{main}->{$key} = Wx::Button -> new($toolpanel, -1, $which, wxDefaultPosition, wxDefaultSize, wxBU_EXACTFIT);
    $app->{main}->{$key}-> SetBackgroundColour( Wx::Colour->new($demeter->co->default("athena", "marked")) );
    $markedbox          -> Add($app->{main}->{$key}, 1, wxALL, 1);
    EVT_BUTTON($app->{main}, $app->{main}->{$key}, sub{$app->plot(@_, $which, 'marked')});
    $app->mouseover($app->{main}->{$key}, "Plot the marked groups in $which");
  };

  $app->{main}->{kweights} = Wx::RadioBox->new($toolpanel, -1, 'Plotting k-weights', wxDefaultPosition, wxDefaultSize,
					       [qw(0 1 2 3 kw)], 1, wxRA_SPECIFY_ROWS);
  $toolbox -> Add($app->{main}->{kweights}, 0, wxALL|wxALIGN_CENTER_HORIZONTAL, 5);
  $app->{main}->{kweights}->SetSelection($demeter->co->default("plot", "kweight"));
  EVT_RADIOBOX($app->{main}, $app->{main}->{kweights},
	       sub {
		 $::app->replot(@{$::app->{lastplot}}) if (lc($::app->{lastplot}->[0]) ne 'e');
	       });
  $app->mouseover($app->{main}->{kweights}, "Select the value of k-weighting to be used in plots in k, R, and q-space.");

  ## -------- fill the plotting options tabs
  $app->{main}->{plottabs}  = Wx::Choicebook->new($toolpanel, -1, wxDefaultPosition, wxDefaultSize, wxNB_TOP);
  $app->mouseover($app->{main}->{plottabs}->GetChildren, "Set various plotting parameters.");
  foreach my $m (qw(Other PlotE PlotK PlotR PlotQ Stack Indicators Style)) {
    next if $INC{"Demeter/UI/Athena/Plot/$m.pm"};
    require "Demeter/UI/Athena/Plot/$m.pm";
    $app->{main}->{$m} = "Demeter::UI::Athena::Plot::$m"->new($app->{main}->{plottabs}, $app);
    $app->{main}->{plottabs} -> AddPage($app->{main}->{$m},
					"Demeter::UI::Athena::Plot::$m"->label,
					($m eq 'PlotE'));
  };
  $toolbox -> Add($app->{main}->{plottabs}, 0, wxGROW|wxALL, 0);

#   my $exafs = Demeter::Plot::Style->new(name=>'exafs', emin=>-200, emax=>800);
#   my $xanes = Demeter::Plot::Style->new(name=>'xanes', emin=>-20,  emax=>80);
#   $app->{main}->{Style}->{list}->Append('exafs', $exafs);
#   $app->{main}->{Style}->{list}->Append('xanes', $xanes);
#   print $exafs->serialization, $xanes->serialization;

  $toolpanel -> SetSizerAndFit($toolbox);

  return $app;
};

sub OnRightDown {
  my ($this, $event) = @_;
  return if $::app->is_empty;
  # my $menu = Wx::Menu->new(q{});
  # $menu->AppendSubMenu($::app->{main}->{groupmenu},  "Group" );
  # $menu->AppendSubMenu($::app->{main}->{markmenu},   "Mark"  );
  # $menu->AppendSubMenu($::app->{main}->{plotmenu},   "Plot"  );
  # $menu->AppendSubMenu($::app->{main}->{freezemenu}, "Freeze");
  # $this->PopupMenu($menu, $event->GetPosition);
  $this->PopupMenu($::app->{main}->{groupmenu}, $event->GetPosition);
  $event->Skip(0);
};

sub OnDrag {
  my ($list, $event) = @_;
  if ($event->ControlDown) {
    my $which = $list->HitTest($event->GetPosition);
    my $source = Wx::DropSource->new( $list );
    my $dragdata = Demeter::UI::Artemis::DND::PlotListDrag->new(\$which);
    $source->SetData( $dragdata );
    $source->DoDragDrop(1);
    $event->Skip(0);
  } else {
    $event->Skip(1);
  };
};

sub OnMark {
  my ($this, $event, $clb) = @_;
  my $n = $event->GetInt;
  my $data = $clb->GetIndexedData($n);
  $data->marked($clb->IsChecked($n));
};

sub focus_up {
  my ($app) = @_;
  my $i = $app->{main}->{list}->GetSelection;
  return if ($i == 0);
  $app->{main}->{list}->SetSelection($i-1);
  $app->OnGroupSelect(q{}, $app->{main}->{list}->GetSelection, 0);
};
sub focus_down {
  my ($app) = @_;
  my $i = $app->{main}->{list}->GetSelection;
  return if ($i == $app->{main}->{list}->GetCount);
  $app->{main}->{list}->SetSelection($i+1);
  $app->OnGroupSelect(q{}, $app->{main}->{list}->GetSelection, 0);
};

sub move_group {
  my ($app, $dir) = @_;
  my $i = $app->{main}->{list}->GetSelection;

  return if (($dir eq 'up')   and ($i == 0));
  return if (($dir eq 'down') and ($i == $app->{main}->{list}->GetCount-1));

  my $from_object  = $app->{main}->{list}->GetIndexedData($i);
  my $from_label   = $app->{main}->{list}->GetString($i);
  my $from_checked = $app->{main}->{list}->IsChecked($i);

  my $to_label     = $app->{main}->{list}->GetString($i-1);

  $app->{main}->{list} -> DeleteData($i);
  my $to = ($dir eq 'down') ? $i+1 : $i-1;

  $app->{main}->{list} -> InsertData($from_label, $to, $from_object);
  $app->{main}->{list} -> Check($to, $from_checked);
  $app->{main}->{list} -> SetSelection($to);
  $app->OnGroupSelect(q{}, $app->{main}->{list}->GetSelection, 0);

  $app->modified(1);
  $app->{main}->status("Moved $from_label $dir");
};


sub OnGroupSelect {
  my ($app, $parent, $event, $plot) = @_;
  if ((ref($event) =~ m{Event}) and (not $event->IsSelection)) { # capture a control click which would otherwise deselect
    $app->{main}->{list}->SetSelection($app->{selected});
    $event->Skip(0);
    return;
  };
  my $is_index = (ref($event) =~ m{Event}) ? $event->GetSelection : $app->{main}->{list}->GetSelection;

  my $was = ((not defined($app->{selected})) or ($app->{selected} == -1)) ? 0 : $app->{main}->{list}->GetIndexedData($app->{selected});
  my $is  = $app->{main}->{list}->GetIndexedData($is_index);
  $app->{selecting_data_group}=1;

  my $showing = $app->{main}->{views}->GetPage($app->{main}->{views}->GetSelection);
  if ($showing =~ m{XDI}) {
    $app->{main}->{XDI}->pull_values($was) if ($was and ($was ne $is));
  };

  if ($is_index != -1) {
    $showing->push_values($is);
    $showing->mode($is, 1, 0);
    $app->{selected} = $app->{main}->{list}->GetSelection;
  };
  $app->{main}->{groupmenu} -> Enable($DATA_TEXT,($app->current_data and (-e $app->current_data->file)));
  $app->{main}->{groupmenu} -> Enable($SHOW_REFERENCE,($app->current_data and $app->current_data->reference));
  $app->{main}->{groupmenu} -> Enable($TIE_REFERENCE,($app->current_data and not $app->current_data->reference));

  my $n = $app->{main}->{list}->GetCount;
  foreach my $x ($PLOT_QUAD, $PLOT_IOSIG, $PLOT_K123, $PLOT_R123) {$app->{main}->{currentplotmenu} -> Enable($x, $n)};
  foreach my $x ($PLOT_E00, $PLOT_I0MARKED                      ) {$app->{main}->{markedplotmenu}  -> Enable($x, $n)};

  $app->select_plot($app->current_data) if $plot;
  $app->{selecting_data_group}=0;
  $app->heap_check(0);
  return;
};

sub select_plot {
  my ($app, $data) = @_;
  return if $app->is_empty;
  return if $app->{main}->{views}->GetSelection; # only on main window
  my $how = lc($data->co->default('athena', 'select_plot'));
  $data->po->start_plot;
  if ($how eq 'quad') {
    $app->quadplot($data);
  } elsif ($how eq 'k123') {
    $app->{main}->{PlotK}->pull_single_values;
    $data->plot('k123');
  } elsif ($how eq 'r123') {
    $app->{main}->{PlotR}->pull_single_values;
    $data->plot('k123');
  } elsif ($how =~ m{\A[ekrq]\z}) {
    $app->plot(0, 0, $how, 'single');
  }; # else $how is none
  return;
};


sub view_changing {
  my ($app, $frame, $event) = @_;
  my $c = (Demeter->co->default(qw(athena show_watcher))) ? 4 : 3;
  my $ngroups = $app->{main}->{list}->GetCount;
  my $nviews  = $app->{main}->{views}->GetPageCount;
  #print join("|", $app, $event, $ngroups, $event->GetSelection), $/;

  my $prior = $app->{main}->{views}->GetPageText($app->{main}->{views}->GetSelection);

  my $string = $app->{main}->{views}->GetPageText($event->GetSelection);
  if ($string =~ m{\A-*\z}) {
    $event -> Veto();
  } elsif (($event->GetSelection != 0) and ($event->GetSelection < $nviews-$c)) {
    if (not $ngroups) {
      $app->{main}->status(sprintf("You have no data imported in Athena, thus you cannot use the %s tool.", lc($string)));
      $event -> Veto();
    };
  } else {
    $app->{main}->{XDI}->pull_values($app->current_data) if $prior =~ m{XDI};
    $app->{main}->status(sprintf("Displaying the %s tool.",
				 lc($app->{main}->{views}->GetPageText($event->GetSelection))));
    #$app->{main}->{showing}=
  };
};

sub marked_groups {
  my ($app) = @_;
  my @list = ();
  foreach my $i (0 .. $app->{main}->{list}->GetCount-1) {
    push(@list, $app->{main}->{list}->GetIndexedData($i)) if $app->{main}->{list}->IsChecked($i);
  };
  return @list;
};

sub plot {
  my ($app, $frame, $event, $space, $how) = @_;
  return if $app->is_empty;
  return if not ($space);
  return if not ($how);

  my $busy = Wx::BusyCursor->new();

  my @data = ($how eq 'single') ? ( $app->current_data ) : $app->marked_groups;
  my @is_fixed = map {$_->bkg_fixstep} @data;

  if (not @data and ($how eq 'marked')) {
    $app->{main}->status("No groups are marked.  Marked plot cancelled.");
    return;
  };

  my $ok = $app->preplot($space, $data[0]);
  return if not $ok;
  my $pause = $data[0]->po->plot_pause*1000;
  ($pause = 0) if ($#data == 0);

  #$app->{main}->{Main}->pull_values($app->current_data);
  $app->pull_kweight($data[0], $how);

  $data[0]->po->single($how eq 'single');
  $data[0]->po->start_plot;
  my $title = ($how eq 'single')                                  ? q{}
            : ($app->{main}->{Other}->{title}->GetValue)          ? $app->{main}->{Other}->{title}->GetValue
            : ($app->{main}->{project}->GetLabel eq '<untitled>') ? 'marked groups'
	    :                                                       $app->{main}->{project}->GetLabel;
  $data[0]->po->title($title);

  my $sp = (lc($space) eq 'kq') ? 'K' : uc($space);
  $sp = 'E' if ($sp =~ m{\A(?:quad|)\z}i);
  $app->{main}->{'Plot'.$sp}->pull_single_values if ($how eq 'single');
  $app->{main}->{'Plot'.$sp}->pull_marked_values if ($how eq 'marked');
  $data[0]->po->chie(0) if (lc($space) eq 'kq');
  $data[0]->po->set(e_bkg=>0) if (($data[0]->datatype eq 'xanes') and (($how eq 'single')));

  ## energy k and kq
  if (lc($space) =~ m{(?:e|k|kq)}) {
    foreach my $d (@data) {
      $d->plot($space);
      usleep($pause) if $pause;
    };
    $data[0]->plot_window('k') if (($how eq 'single') and
				   $app->{main}->{PlotK}->{win}->GetValue and
				   ($data[0]->datatype ne 'xanes') and
				   (lc($space) ne 'e'));
    if (lc($space) eq 'e') {
      $app->{main}->{plottabs}->SetSelection(1) if $app->spacetab;
    } else {
      $app->{main}->{plottabs}->SetSelection(2) if $app->spacetab;
    };

  ## R
  } elsif (lc($space) eq 'r') {
    if ($how eq 'single') {
      $data[0]->po->dphase($app->{main}->{PlotR}->{dphase}->GetValue);
      foreach my $which (qw(mag env re im pha)) {
	if ($app->{main}->{PlotR}->{$which}->GetValue) {
	  $data[0]->po->r_pl(substr($which, 0, 1));
	  $data[0]->plot('r');
	};
      };
      $data[0]->plot_window('r') if $app->{main}->{PlotR}->{win}->GetValue;
    } else {
      $data[0]->po->dphase($app->{main}->{PlotR}->{mdphase}->GetValue);
      foreach my $d (@data) {
	$d->plot($space);
	usleep($pause) if $pause;
      };
    };
    $app->{main}->{plottabs}->SetSelection(3) if $app->spacetab;

  ## q
  } elsif (lc($space) eq 'q') {
    if ($how eq 'single') {
      foreach my $which (qw(mag env re im pha)) {
	if ($app->{main}->{PlotQ}->{$which}->GetValue) {
	  $data[0]->po->q_pl(substr($which, 0, 1));
	  $data[0]->plot('q');
	};
      };
      $data[0]->plot_window('q') if $app->{main}->{PlotQ}->{win}->GetValue;
    } else {
      foreach my $d (@data) {
	$d->plot($space);
	usleep($pause) if $pause;
      };
    };
    $app->{main}->{plottabs}->SetSelection(4) if $app->spacetab;
  };

  ## I am not clear why this is necessary...
  foreach my $i (0 .. $#data) {
    $data[$i]->bkg_fixstep($is_fixed[$i]);
  };
  $app->postplot($data[0], $is_fixed[0]);
  $app->{lastplot} = [$space, $how];
  $app->heap_check(0);
  undef $busy;
};

sub spacetab {
  my ($app) = @_;
  my $n = $app->{main}->{plottabs}->GetSelection;
  return (($n > 0) and ($n < 5));
};

sub preplot {
  my ($app, $space, $data) = @_;
  if ($app->{main}->{Other}->{singlefile}->GetValue) {
    ## writing plot to a single file has been selected...
    my $fd = Wx::FileDialog->new( $app->{main}, "Save plot to a file", cwd, "plot.dat",
				  "Data (*.dat)|*.dat|All files|*",
				  wxFD_SAVE|wxFD_CHANGE_DIR, #|wxFD_OVERWRITE_PROMPT,
				  wxDefaultPosition);
    if ($fd->ShowModal == wxID_CANCEL) {
      $app->{main}->status("Saving plot to a file has been cancelled.");
      $app->{main}->{Other}->{singlefile}->SetValue(0);
      return 0;
    };
    ## set up for SingleFile backend
    my $file = $fd->GetPath;
    $app->{main}->{Other}->{singlefile}->SetValue(0), return
      if $app->{main}->overwrite_prompt($file); # work-around gtk's wxFD_OVERWRITE_PROMPT bug (5 Jan 2011)

    if (not $data) {
      foreach my $i (0 .. $app->{main}->{list}->GetCount-1) {
	if ($app->{main}->{list}->IsChecked($i)) {
	  $data = $app->{main}->{list}->GetIndexedData($i);
	  last;
	};
      };
    };
    $demeter->plot_with('singlefile');
    $data->po->prep(file     => $file,
		    standard => $data,
		    space    => $space);
    #$data->standard;
    #$data->po->space($space);
    #$demeter->po->file(File::Spec->catfile($fd->GetDirectory, $fd->GetFilename));
  };
  $data->po->plot_pause($app->{main}->{Other}->{pause}->GetValue);
  return 1;
};
sub postplot {
  my ($app, $data) = @_;
  ##if ($demeter->mo->template_plot eq 'singlefile') {
  if ($app->{main}->{Other}->{singlefile}->GetValue) {
    $demeter->po->finish;
    $app->{main}->status("Wrote plot data to ".$demeter->po->file);
    $demeter->plot_with($demeter->co->default(qw(plot plotwith)));
  } else {
    $data->standard;
    $app->{main}->{Indicators}->plot;
    $data->unset_standard;
  };
  my $is_fixed = $data->bkg_fixstep;
  if ($data eq $app->current_data) {
    $app->{main}->{Main}->{bkg_step}->SetValue($app->current_data->bkg_step);
    $app->{main}->{Main}->{bkg_fixstep}->SetValue($is_fixed);
  };
  $data->bkg_fixstep($is_fixed);

  $app->{main}->{Other}->{singlefile}->SetValue(0);
  return;
};

sub quadplot {
  my ($app, $data) = @_;
  if ($data->datatype eq 'xanes') {
    $app->plot(q{}, q{}, 'E', 'single')
  } elsif ($data->datatype eq 'chi') {
    $app->plot(q{}, q{}, 'k', 'single')
  } elsif ($data->mo->template_plot eq 'gnuplot') {
    my ($showkey, $fontsize) = ($data->po->showlegend, $data->co->default("gnuplot", "fontsize"));
    $data->po->showlegend(0);
    $data->co->set_default("gnuplot", "fontsize", 8);

    $app->{main}->{PlotE}->pull_single_values;
    $app->{main}->{PlotK}->pull_single_values;
    $app->{main}->{PlotR}->pull_marked_values;
    $app->{main}->{PlotQ}->pull_marked_values;
    $app->pull_kweight($data, 'single');
    $data->plot('quad');

    $data->po->showlegend($showkey);
    $data->co->set_default("gnuplot", "fontsize", $fontsize);
    $app->{lastplot} = ['quad', 'single'];
  } else {
    $app->plot(q{}, q{}, 'E', 'single')
  };
};

sub plot_e00 {
  my ($app) = @_;

  $app->preplot('e', $app->current_data);
  $app->{main}->{PlotE}->pull_single_values;
  $app->current_data->po->set(e_mu=>1, e_markers=>0, e_zero=>1, e_bkg=>0, e_pre=>0, e_post=>0,
			      e_norm=>1, e_der=>0, e_sec=>0, e_i0=>0, e_signal=>0);
  $app->current_data->po->start_plot;
  $app->current_data->po->title($app->{main}->{Other}->{title}->GetValue);
  foreach my $i (0 .. $app->{main}->{list}->GetCount-1) {
    $app->{main}->{list}->GetIndexedData($i)->plot('e')
      if $app->{main}->{list}->IsChecked($i);
  };
  $app->current_data->po->set(e_zero=>0, e_markers=>1);
  $app->postplot($app->current_data);
};
sub plot_i0_marked {
  my ($app) = @_;

  $app->preplot('e', $app->current_data);
  $app->{main}->{PlotE}->pull_single_values;
  $app->current_data->po->set(e_mu=>0, e_markers=>0, e_zero=>0, e_bkg=>0, e_pre=>0, e_post=>0,
			      e_norm=>0, e_der=>0, e_sec=>0, e_i0=>1, e_signal=>0);
  $app->current_data->po->start_plot;
  $app->current_data->po->title($app->{main}->{Other}->{title}->GetValue);
  foreach my $i (0 .. $app->{main}->{list}->GetCount-1) {
    $app->{main}->{list}->GetIndexedData($i)->plot('e')
      if $app->{main}->{list}->IsChecked($i);
  };
  $app->current_data->po->set(e_i0=>0, e_markers=>1);
  $app->postplot($app->current_data);
};

sub pull_kweight {
  my ($app, $data, $how) = @_;
  my $kw = $app->{main}->{kweights}->GetStringSelection;
  if ($kw eq 'kw') {
    #$data->po->kweight($data->fit_karb_value);
    if ($how eq 'single') {
      $data->po->kweight($data->fit_karb_value);
    } else {
      ## check to see if marked groups all have the same arbitrary k-weight
      my @kweights = map {$_->fit_karb_value} $app->marked_groups;
      my $nuniq = grep {abs($_-$kweights[0]) > $EPSI} @kweights;
      $data->po->kweight($data->fit_karb_value);
      $data->po->kweight(-1) if $nuniq; # variable k-weighting if not all the same
    };
  } else {
    $data->po->kweight($kw);
  };
  return $data->po->kweight;
};


my %mark_feeedback = (all	    => "Marked all groups.",
		      none	    => "Cleared all marks",
		      invert	    => "Inverted all marks",
		      toggle	    => "Toggled mark for current data group",
		      regexp	    => "Marked all groups matching ",
		      unmark_regexp => "Unmarked all groups matching ",);
sub mark {
  my ($app, $how) = @_;
  my $clb = $app->{main}->{list};
  return if not $clb->GetCount;

  my $regex = q{};
  if (ref($how) =~ m{Demeter}) {
    foreach my $i (0 .. $clb->GetCount-1) {
      if ($clb->GetIndexedData($i)->group eq $how->group) {
	$clb->Check($i,1);
	$clb->GetIndexedData($i)->marked(1);
	last;
      };
    };
  } elsif ($how eq 'toggle') {
    $clb->Check($clb->GetSelection, not $clb->IsChecked($clb->GetSelection));
    $clb->GetIndexedData($::app->current_index)->marked($clb->IsChecked($::app->current_index));
    return;

  } elsif ($how =~ m{all|none|invert}) {
    foreach my $i (0 .. $clb->GetCount-1) {
      my $val = ($how eq 'all')    ? 1
	      : ($how eq 'none')   ? 0
	      : ($how eq 'invert') ? not $clb->IsChecked($i)
	      :                     $clb->IsChecked($i);
      $clb->Check($i, $val);
      $clb->GetIndexedData($i)->marked($val);
    };

  } else {			# regexp mark or unmark
    my $word = ($how eq 'regexp') ? 'Mark' : 'Unmark';
    my $ted = Wx::TextEntryDialog->new( $app->{main}, "$word data groups matching this regular expression:", "Enter a regular expression", q{}, wxOK|wxCANCEL, Wx::GetMousePosition);
    $app->set_text_buffer($ted, "regexp");
    if ($ted->ShowModal == wxID_CANCEL) {
       $app->{main}->status($word."ing by regular expression cancelled.");
      return;
    };
    $regex = $ted->GetValue;
    my $re;
    my $is_ok = eval '$re = qr/$regex/';
    if (not $is_ok) {
      $app->{main}->status("Oops!  \"$regex\" is not a valid regular expression");
      return;
    };
    $app->update_text_buffer("regexp", $regex, 1);

    foreach my $i (0 .. $clb->GetCount-1) {
      next if ($clb->GetIndexedData($i)->name !~ m{$re});
      my $val = ($how eq 'regexp') ? 1 : 0;
      $clb->Check($i, $val);
      $clb->GetIndexedData($i)->marked($val);
    };
  };
  if (ref($how) !~ m{Demeter}) {
    my $text = $mark_feeedback{$how};
    $text .= '/'.$regex.'/' if ($how =~ m{regexp});
    $app->{main}->status($text);
  };
};


sub merge {
  my ($app, $how, $noplot) = @_;
  return if $app->is_empty;
  $noplot ||= 0;
  my $busy = Wx::BusyCursor->new();
  my @data = ();
  my $max = 0;
  foreach my $i (0 .. $app->{main}->{list}->GetCount-1) {
    my $this = $app->{main}->{list}->GetIndexedData($i);
    if ($this->name =~ m{\A\s*merge\s*(\d*)\s*\z}) {
      $max = $1 if (looks_like_number($1) and ($1 > $max));
      $max ||= 1;
    };
    push(@data, $this) if $app->{main}->{list}->IsChecked($i);
  };
  if (not @data) {
    $app->{main}->status("No groups are marked.  Merge cancelled.");
    undef $busy;
    return;
  };

  $app->{main}->status("Merging marked groups");
  my $merged = $data[0]->merge($how, @data);
  $max = q{} if not $max;
  $max = sprintf(" %d", $max+1) if $max;
  $merged->name('merge'.$max);
  $app->{main}->{list}->AddData($merged->name, $merged);
  my $n = 1;

  if ($data[0] -> reference) {
    my @refs = grep {$_} map  {$_->reference} @data;
    $app->{main}->status("Merging marked groups");
    my $refmerged = $refs[0]->merge($how, @refs);
    $refmerged->name("  Ref ". $merged->name);
    $refmerged->reference($merged);
    $app->{main}->{list}->AddData($refmerged->name, $refmerged);
    $n = 2;
  };

  $app->{main}->{list}->SetSelection($app->{main}->{list}->GetCount-$n);
  $app->OnGroupSelect(q{}, $app->{main}->{list}->GetSelection, 0);
  $app->{main}->{Main}->mode($merged, 1, 0);
  $app->{main}->{list}->Check($app->{main}->{list}->GetCount-$n, 1);
  $merged->marked(1);
  $app->modified(1);

  ## handle plotting, respecting the choice in the athena->merge_plot config parameter
  if (not $noplot) {
    my $plot = $merged->co->default('athena', 'merge_plot');
    if ($plot =~ m{stddev|variance}) {
      $app->{main}->{PlotE}->pull_single_values;
      $app->{main}->{PlotK}->pull_single_values;
      $merged->plot($plot);
    } elsif (($plot eq 'marked') and ($how =~ m{\A[en]\z})) {
      $app->{main}->{PlotE}->pull_single_values;
      $merged->po->set(e_mu=>1, e_bkg=>0, e_pre=>0, e_post=>0, e_norm=>0, e_der=>0, e_sec=>0, e_markers=>0, e_i0=>0, e_signal=>0);
      $merged->po->set(e_norm=>1) if ($how eq 'n');
      $merged->po->start_plot;
      $_->plot('e') foreach (@data, $merged);
    } elsif (($plot eq 'marked') and ($how eq 'k')) {
      $app->{main}->{PlotK}->pull_single_values;
      $merged->po->chie(0);
      $merged->po->start_plot;
      $_->plot('k') foreach (@data, $merged);
    };
    $merged->po->e_markers(1);
  };
  $app->{main}->status("Made merged data group");
  $app->heap_check(0);
  undef $busy;
};

sub modified {
  my ($app, $is_modified) = @_;
  $app->{modified} += $is_modified;
  $app->{modified} = 0 if not $is_modified;
  $app->{main}->{save}->Enable($is_modified);
  my $token = ($is_modified) ? q{*} : q{ };
  $app->{main}->{token}->SetLabel($token);
  #   my $projname = $app->{main}->{project}->GetLabel;
  #   return if ($projname eq '<untitled>');
  #   $projname = substr($projname, 1) if ($projname =~ m{\A\*});
  #   $projname = '*'.$projname if ($is_modified);
  #   $app->{main}->{project}->SetLabel($projname);

  my $c = $app->{main}->{save_start_color};
  $app->{main}->{save}->SetBackgroundColour($c) if not $is_modified;
  my $j = $demeter->co->default('athena', 'save_alert');
  $app->autosave if ($app->{modified} % $demeter->co->default('athena', 'autosave_frequency') == 0);
  return if ($j <= 0);
  my $n = min( 1, $app->{modified}/$j );
  if ($app->{modified}) {
    my ($r, $g, $b) = ($c->Red, $c->Green, $c->Blue);
    $r = int( min ( 255, $r + (255 - $r) * 2 * $n ) );
    $g = int($g * (1-$n));
    $b = int($b * (1-$n));
    ##print join(" ", $r, $g, $b), $/;
    $app->{main}->{save}->SetBackgroundColour(Wx::Colour->new($r, $g, $b));
  } else {
    $app->{main}->{save}->SetBackgroundColour($c);
  };
};

sub autosave {
  my ($app, $j) = @_;
  return if ($app->{modified} == 0);
  return if not $demeter->co->default('athena', 'autosave');
  return if ($demeter->co->default('athena', 'autosave_frequency') < 1);
  $app->{main}->status("Performing autosave ...", "wait|nobuffer");
  $app -> Export('all', File::Spec->catfile($demeter->stash_folder, $AUTOSAVE_FILE));
  $app->{main}->status("Successfully performed autosave.");
};

sub Clear {
  my ($app) = @_;
  $app->{main}->{currentproject} = q{};
  $app->{main}->{project}->SetLabel('<untitled>');
  $app->modified(not $app->is_empty);
  $app->{main}->status(sprintf("Unamed the current project."));
};

## in future times, check to see if Ifeffit is being used
sub heap_check {
  my ($app, $show) = @_;
  if ($app->current_data->mo->heap_used > 0.98) {
    $app->{main}->status("You have used all of Ifeffit's memory!  It is likely that your data is corrupted!", "error");
  } elsif ($app->current_data->mo->heap_used > 0.95) {
    $app->{main}->status("You have used more than 95% of Ifeffit's memory.  Save your work!", "error");
  } elsif ($app->current_data->mo->heap_used > 0.9) {
    $app->{main}->status("You have used more than 90% of Ifeffit's memory.  Save your work!", "error");
  } elsif ($show) {
    $app->current_data->ifeffit_heap;
    $app->{main}->status(sprintf("You are currently using %.1f%% of Ifeffit's %.1f Mb of memory",
				 100*$app->current_data->mo->heap_used,
				 $app->current_data->mo->heap_free/(1-$app->current_data->mo->heap_used)/2**20));
  };
};

sub document {
  my ($app, $which) = @_;
  print "show document for $which\n";
};

=for Explain

Every window in Athena is a Wx::Frame.  This inserts a method into
that namespace which serves as a choke point for writing messages to
the status bar.  The two purposes served are (1) to apply some color
to the text in the status bar and (2) to log all such messages.  The
neat thing about doing it this way is that each window will write to
its own status bar yet all messages get captured to a common log.

  $wxframe->status($text, $type);

where the optional $type is one of "normal", "error", or "wait", each
of which corresponds to a different text style in both the status bar
and the log buffer.  $type of "nobuffer" will display the status
message, but not push it into the buffer.

=cut

package Wx::Frame;
use Wx qw(wxNullColour);
use Demeter::UI::Wx::OverwritePrompt;
my $normal = wxNullColour;
my $wait   = Wx::Colour->new("#C5E49A");
my $error  = Wx::Colour->new("#FD7E6F");
my $debug  = 0;
sub status {
  my ($self, $text, $type) = @_;
  $type ||= 'normal';

  if ($debug) {
    local $|=1;
    print $text, " -- ", join(", ", (caller)[0,2]), $/;
  };

  my $color = ($type =~ m{normal}) ? $normal
            : ($type =~ m{wait})   ? $wait
            : ($type =~ m{error})  ? $error
	    :                       $normal;
  $self->GetStatusBar->SetBackgroundColour($color);
  $self->GetStatusBar->SetStatusText($text);
  return if ($type =~ m{nobuffer});
  $self->{Status}->put_text($text, $type);
  $self->Refresh;
};

# sub OnCreateStatusBar {
#   my ($self, $number, $style, $id, $name);
#   print "Hi!\n";
#   return Demeter::UI::Wx::EchoArea->new($self);
# };

=for Explain

According to the wxWidgets documentation, "Please note that
wxCheckListBox uses client data in its implementation, and therefore
this is not available to the application."  This appears either not to
be true on Linux or, perhaps, that the client data is overwritable
with no ill effect.  On Windows, however, attempting to set client
data crashes the application.

On the wxperl-users mailing list Mattia Barbon said: "It's a wxWidgets
limitation: it uses the same Win32 client data slot in wxListBox to
store client data, in wxCheckListBox to store the boolean state of the
item."

Sigh....

These methods are an attempt to replicate the effect of client data by
maintaining a list of pointers to data that is indexed to the
CheckListBox.  This list is stored in the underlying hash of the
CheckListBox object.  The trick is to keep the list in sync with the
displayed content of the CheckListBox at all times.

Yes, this *is* much to complicated.

=cut

package Wx::CheckListBox;
use Wx qw(:everything);
sub AddData {
  my ($clb, $name, $data) = @_;
  $clb->Append($name);
  $clb->Check($clb->GetCount-1, $data->marked);
  push @{$clb->{datalist}}, $data;
};

sub InsertData {
  my ($clb, $name, $n, $data) = @_;
  $clb->Insert($name, $n);
  my @list = @{$clb->{datalist}};
  splice(@list, $n, 0, $data);
  $clb->{datalist} = \@list;
};

sub GetIndexedData {
  my ($clb, $n) = @_;
  return $clb->{datalist}->[$n];
};

sub DeleteData {
  my ($clb, $n) = @_;

  ## remove from the Indexed array
  my @list = @{$clb->{datalist}};
  my $gone = splice(@list, $n, 1);
  #print $gone, "  ", $gone->name, $/;
  $clb->{datalist} = \@list;

  $clb->Delete($n); # this calls the selection event on the new item
};

sub ClearAll {
  my ($clb) = @_;
  $clb->{datalist} = [];
  $clb->Clear;
};


package Demeter::UI::Athena::DropTarget;

use Wx qw( :everything);
use base qw(Wx::DropTarget);
use Demeter::UI::Artemis::DND::PlotListDrag;

use Scalar::Util qw(looks_like_number);

sub new {
  my $class = shift;
  my $this = $class->SUPER::new;

  my $data = Demeter::UI::Artemis::DND::PlotListDrag->new();
  $this->SetDataObject( $data );
  $this->{DATA} = $data;
  return $this;
};

sub OnData {
  my ($this, $x, $y, $def) = @_;

  my $list = $::app->{main}->{list};
  return 0 if not $list->GetCount;
  $this->GetData;		# this line is what transfers the data from the Source to the Target

  my $from = ${ $this->{DATA}->{Data} };
  my $from_object  = $list->GetIndexedData($from);
  my $from_label   = $list->GetString($from);
  my $from_checked = $list->IsChecked($from);
  my $point = Wx::Point->new($x, $y);
  my $to = $list->HitTest($point);
  my $to_label   = $list->GetString($to);

  return 0 if ($to == $from);	# either of these two would leave the list in the same state
#  return 0 if ($to == $from+1);

  my $message;
  $list -> DeleteData($from);
  if ($to == -1) {
    $list -> AddData($from_label, $from_object);
    $list -> Check($list->GetCount-1, $from_checked);
    $::app->{main}->{list}->SetSelection($from);
    $message = sprintf("Moved '%s' to the last position.", $from_label);
  } else {
    $message = sprintf("Moved '%s' above %s.", $from_label, $to_label);
    --$to if ($from < $to);
    $list -> InsertData($from_label, $to, $from_object);
    #$list -> SetClientData($to, $from_object);
    $list -> Check($to, $from_checked);
    $::app->{main}->{list}->SetSelection($to);
  };
  $::app->OnGroupSelect(q{}, $::app->{main}->{list}->GetSelection, 0);
  $::app->modified(1);
  $::app->{main}->status($message);

  return $def;
};

1;



=head1 NAME

Demeter::UI::Athena - XAS data processing

=head1 VERSION

This documentation refers to Demeter version 0.9.

=head1 SYNOPSIS

This short program launches Athena:

  use Wx;
  use Demeter::UI::Athena;
  Wx::InitAllImageHandlers();
  my $window = Demeter::UI::Athena->new;
  $window -> MainLoop;

=head1 DESCRIPTION

Athena is ...

=head1 USE

Using ...

=head1 CONFIGURATION

Many aspects of Athena and its UI are configurable using the
configuration ...

=head1 DEPENDENCIES

This is a Wx application.  Demeter's dependencies are in the
F<Bundle/DemeterBundle.pm> file.

=head1 BUGS AND LIMITATIONS

=over 4

=item *

Many, many, many ...

=back

Please report problems to Bruce Ravel (bravel AT bnl DOT gov)

Patches are welcome.

=head1 AUTHOR

Bruce Ravel (bravel AT bnl DOT gov)

L<http://cars9.uchicago.edu/~ravel/software/>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2006-2012 Bruce Ravel (bravel AT bnl DOT gov). All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlgpl>.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
