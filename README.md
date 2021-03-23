# BCI2000toBIDS
This repository contains code and documentation to help convert BCI2000 data to BIDS.

**Welcome to the BCI2000 to BIDS repository**

We are working on developing code to read BCI2000 data and then write a folder containing a BIDS-compatible dataset.

# BCI 20000
Acquisition of and real-time interaction with electrophysiological signals can be accomplished with many different bio-signal acquisition devices. The [BCI2000][BCI2000] general-purpose software platform provides an open-source solution to abstracting a wide range of bio-signal acquisition devices, synchronizing their signals to a variety of other devices that capture behavior (e.g., eye-trackers, data-gloves, etc.), and closed-loop experiments. BCI2000’s large high-quality code base is documented by a comprehensive set of technical references that is available as a [wiki](http://doc.bci2000.org).

# BIDS
The Brain Imaging Data Structure ([BIDS]([bids]) specifies a standard folder structure for many different electrophysiological signals, such as EEG, MEG and intracranial EEG, imaging data and is rapidly growing with ongoing proposals to extend BIDS. Metadata are both human- and machine-readable and their fields are prescribed to allow for automated processing.

# Dependencies
In order to read and write BIDS metadata files (.json and .tsv) you need some packages highlighted below.

## MATLAB / Octave (Free, open source equivalent)
***MATLAB Information***: https://www.mathworks.com/products/matlab.html

***Octave Information***: https://www.gnu.org/software/octave/

Required JSON package
**JSONio**

	Install Link: https://github.com/gllmflndn/JSONio


## Python
***Information***: https://www.python.org/ (Both Python 2 and 3 will work for BIDS)

**Anaconda** Recommended package to use for installing Python

	Install Link: https://conda.io/docs/user-guide/install/download.html

**Pandas**
Pandas is already included in Anaconda, but use the link below if you just want the data analysis library.

	Install Link: https://pandas.pydata.org/
