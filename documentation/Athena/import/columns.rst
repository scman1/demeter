.. _column_selection_sec:

Column selection dialog
=======================

Converting raw data to mu(E)
----------------------------

To import a data file, select Open file from the File menu or type
``Control-o``. Alternately, you can drag one or more data files from
your computer's file manager and drop them onto the group list. A file
selection dialog opens. On my Linux computer, it looks like this:

.. _fig-import_filedialog:

.. figure:: ../images/import_filedialog.png
   :target: ../images/import_filedialog.png
   :width: 75%
   :align: center

   The file selection dialog on a Linux computer.

It looks somewhat different on Windows, but behaves the same. It allows
you to navigate your disk to find the file you want to import. Once you
find that file, click on it then click on the Open button.

Once you have selected a file to import the column selection dialog,
shown below, appears.

On the right side of this dialog, the contents of the data file are
displayed. This allows you to examine the file to help you figure out
which columns should be imported to turn into the |mu| (E) data.

On the left are various control for specifying which columns contain the
energy values and which contain the signals from the various detectors.
Typically, the signals from the detectors are saved to disk as columns
of numbers. These columns need to be combined depending on the nature of
the experiment. For a transmission experiment, the incident channel is
divided by transmission channel and the natural log is taken at each
point. For fluorescence data, the fluorescence channel is divided by the
incidence channel. Electron yield data is like fluorescence data -- the
yield channel is divided by the incident channel.

The controls in the tabs at the bottom left are the discussed in later
sections.

.. _fig-import_colsel:

.. figure:: ../images/import_colsel.png
   :target: ../images/import_colsel.png
   :width: 75%
   :align: center

   The column selection dialog.

In the example shown, the incident channel is, for some reason, called
:quoted:`mcs3`. Since this is transmission data, I have checked the :quoted:`mcs3`
button for the numerator. The transmission channel is called :quoted:`mcs4` and
its button is checked for the denominator.

As you check the buttons, some helpful things happen. The first is that
equation for how the columns combine to form |mu| (E) is displayed in the
box below the column selection buttons. Also as you check buttons, the
data are plotted. If you have selected the correct columns and chosen
the numerator and denominator correctly, the plot will look like XAS
data. If the plot is upside-down, then you need to switch the numerator
and denominator. If the plot doesn't look like XAS at all, you need to
try some of the other channels.

I chose this example because the columns are labeled somewhat
confusingly. Often the columns will be labeled in the file more
obviously with names like :quoted:`I0` or :quoted:`It`. In this case, we either need to
know what the columns mean or patiently click through the buttons to
figure it out. As a last resort, you may need to ask the beamline
scientist!



Data types and energy units
---------------------------

Occasionally, :demeter:`athena` needs a bit more information to interpret your data
correctly. The data types menu is shown in the figure below. The default
is for data to be imported as |mu| (E).

The other choices are:

-  xanes(E) : |mu| (E) data measured over a limited data range and for which
   you do not need to look at the |chi| (k)

-  norm(E) : |mu| (E) data that have already been normalized in some other
   way. These data will not be normalized by :demeter:`athena`

-  chi(k) : |chi| (k) data, that is data that have already been background
   subtracted from |mu| (E)

-  xmu.dat : the xmu.dat file from FEFF

.. _fig-import_types:

.. figure:: ../../images/import_types.png
   :target: ../../images/import_types.png
   :width: 75%
   :align: center

   Data types in the column selection dialog.

.. _fig-import_changetype:

.. figure:: ../../images/import_changetype.png
   :target: ../../images/import_changetype.png
   :width: 40%
   :align: center

   The dialog for changing data type of a group.

If you make a mistake and import your data as the wrong data type, you
can change between any of the energy-valued (|mu| (E), normalized |mu|
(E), XANES, or detector) record types at any time by selecting
:quoted:`Change data type` from the Group menu and selecting the
correct choice from the popup dialog, shown here. This dialog cannot,
however, be used to change |chi| (k) data to an energy-value type or
vice-versa, nor to change one of the :demeter:`feff` types to a
non-:demeter:`feff` type.

:demeter:`athena` uses electron volts as its energy unit. It uses a simple
heuristic to figure out if an input file is in eV or keV. In case :demeter:`athena`
gets it wrong, you can specify the energy unit with the :quoted:`Energy units`
menu. `Dispersive XAS <../process/pixel.html>`__, i.e. data which is a
function of pixel index, requires special treatment.

.. versionadded:: 0.9.20
   There is now a label on the main page right next to the
   :quoted:`Freeze` button which identifies the file type of the data. You can
   toggle between xanes and xmu data by ``Control-Alt-Left`` clicking on that
   label.


Multi-element detector data
---------------------------

:demeter:`athena`'s column selection dialog has some special features for dealing
with multi-element detectors. You can select all the channels of the MED
as elements of the numerator, as shown in this example of the column
selection dialog.

.. _fig-import_med:

.. figure:: ../images/import_med.png
   :target: ../images/import_med.png
   :width: 75%
   :align: center

   Importing multi-element data in the column selection dialog.

Importing the data will then add up the channels on the fly and put a
group containing the summation of the channels in the group list.

You have the option of clicking the button that says :quoted:`Save
each channel as a group`, as shown here.

.. _fig-import_medch:

.. figure:: ../images/import_medch.png
   :target: ../images/import_medch.png
   :width: 75%
   :align: center

   Importing multi-element data in the column selection dialog and saving
   each channel as a group.

Then, instead of adding the channels to make one group, each channel
will be imported as an individual group and given its own entry in the
group list. This is handy for examining the channels and discarding any
that are not of usable quality.

.. _fig-import_medchimported:

.. figure:: ../images/import_medchimported.png
   :target: ../images/import_medchimported.png
   :width: 75%
   :align: center

   After importing the channels of multi-element data as individual groups.
