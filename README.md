# BCI2000-BIDS_converter
MATLAB-based framework for converting BCI2000 ".dat" recordings into BIDS-compatible electrophysiology datasets.
==========================

Overview
--------

This project provides a MATLAB-based framework for converting BCI2000 `.dat`
recordings into BIDS-compatible electrophysiology datasets.

The architecture is divided into two layers:

1. GUI layer
   - Selects input BCI2000 recordings.
   - Selects a conversion profile.
   - Collects BIDS entities such as subject, session, task, acquisition, and run.
   - Selects the desired output signal format.
   - Calls the `BCI2000_data` class for each selected recording.

2. Conversion layer (`BCI2000_data`)
   - Loads one BCI2000 `.dat` recording.
   - Loads a JSON conversion profile.
   - Applies metadata mappings.
   - Loads and activates optional extension profiles.
   - Applies profile-defined preprocessing.
   - Adds auxiliary BCI2000 states as channels.
   - Converts selected states to `events.tsv`.
   - Generates BIDS JSON sidecars.
   - Handles stimulation metadata.
   - Writes custom stimulation-parameter JSON files when applicable.
   - Dispatches signal writing to format-specific external conversion functions.

The `BCI2000_data` class represents a single BCI2000 recording.

Current files
-------------

BCI2000_data.m
    Main MATLAB class representing one BCI2000 recording and its conversion state.

BCI2000_to_BIDS_GUI.mlapp / BCI2000_to_BIDS_GUI.m
    App Designer front end for selecting recordings and BIDS conversion settings.

dat2mef.m
    External MEF3 signal writer using the `mef3io` package.

dat2edf.m
    External EDF writer using MATLAB EDF functionality.

parseBCI2000_parameters_values.m
    Helper used to parse BCI2000 matrix/list parameters into MATLAB tables.

conversionProfiles/
    Directory containing base conversion profiles and optional extension profiles.

Basic usage
-----------

A single recording can be converted directly without using the GUI:

    data = BCI2000_data( ...
        "/path/to/recording.dat", ...
        "/path/to/conversionProfiles/CorTecBIC_profile.json");

    data.setBIDSContext("c01", "closedLoop", "motor");

    data.convert2BIDS( ...
        "/output/sub-c01/ses-closedLoop/ieeg/" + ...
        "sub-c01_ses-closedLoop_task-motor_ieeg.mefd");

The class handles loading, profile application, preprocessing, auxiliary states,
events, sidecars, stimulation metadata, and format dispatch.

**Dependencies**
===============================
The BCI2000-to-BIDS converter relies on the following external software:

* BCI2000 MATLAB MEX Files – Required for reading and writing BCI2000 .dat files (load_bcidat, save_bcidat, read_bcidate).
   * https://bci2000.org/externals/mex/mexfiles.zip 
* MEF3IO – Required for exporting recordings to the Multiscale Electrophysiology Format (MEF3).
   *    https://github.com/bnelair/mef3io
* BIDS Validator (recommended) – Recommended for validating the generated BIDS dataset prior to sharing or publication.
   * https://bids-standard.github.io/bids-validator/
* MATLAB Signal Processing Toolbox – Required only for EDF export (edfwrite, edfheader).

Conversion profile architecture
===============================

Conversion profiles are JSON files that describe how BCI2000 parameters and
states should be interpreted for a particular device, source module, task, or
optional BCI2000 extension.

The goal is to keep device-specific logic in JSON whenever possible and keep
`BCI2000_data` generic.

There are three main profile categories:

1. Base conversion profiles
2. Extension profiles
3. Task/stimulation profiles

Base conversion profiles
------------------------

A base profile defines the main acquisition hardware and the canonical metadata
that should be extracted from the BCI2000 file.

Examples:

    BCI2000_Generic_profile.json
    CorTecBIC_profile.json
    gHIamp_profile.json
    gHIamp_FunctionalData.json
    gHIamp_Stimulation.json

A typical base profile contains:

    {
      "profileName": "gHIamp",
      "profileVersion": "0.1.0",
      "description": "...",
      "modality": "iEEG",
      "metadata": {
        "Device": { ... },
        "Recording": { ... },
        "Provenance": { ... }
      },
      "events": [ ... ],
      "preprocessing": [ ... ],
      "extensions": [ ... ],
      "stimulation": { ... }
    }

Profile identity fields
-----------------------

profileName
    Unique profile name.

profileVersion
    Version string for the profile. Increment this when mapping behavior changes.

description
    Human-readable description.

modality
    BIDS modality currently used by the converter. Current intracranial profiles
    generally use `"iEEG"`.

Metadata mappings
=================

The `metadata` field maps BCI2000 parameters into canonical metadata used by
`BCI2000_data`.

Example:

    "SamplingFrequency": {
      "source": "parameter",
      "path": "SamplingRate",
      "aliases": ["Source.SamplingRate"],
      "required": true,
      "transform": "parseNumeric"
    }

The corresponding output becomes:

    data.Metadata.Recording.SamplingFrequency

Supported mapping fields
------------------------

source
    Defines where the value comes from. Common values are `"parameter"` and
    `"constant"`.

path
    Name/path of the BCI2000 parameter.

aliases
    Optional alternative parameter paths to try when the primary path is not
    available.

required
    If true, failure to resolve the field is treated as a validation error.

default
    Fallback value when no source parameter is available.

value
    Constant value used when `"source": "constant"`.

transform
    Transformation applied after extracting the value.

valueIndex
    Optional matrix/cell index used for BCI2000 parameters whose `Value` field
    is a matrix.

Example:

    "SourceModule": {
      "source": "parameter",
      "path": "SignalSourceFilterChain",
      "valueIndex": [2, 1],
      "default": "gHIampADC",
      "transform": "toString"
    }

Common metadata transforms
--------------------------

parseNumeric
    Converts common BCI2000 numeric representations into MATLAB doubles.

toString
    Converts the resolved value into a MATLAB string.

Datetime
    Converts a BCI2000 date/time field such as `StorageTime` into MATLAB
    `datetime`.

joinStrings
    Joins a list/matrix of strings into a single readable value.

extractUnitsFromGain
    Extracts physical units from `SourceChGain` entries and normalizes them for
    channel metadata.

Additional transforms may be added to `BCI2000_data` when required by future
devices.

Nested metadata
---------------

Profiles may define nested metadata structures.

Example:

    "HardwareFilters": {
      "BandPassFilter": {
        "Enabled": {
          "source": "parameter",
          "path": "FilterEnabled",
          "transform": "parseNumeric"
        },
        "HighPassCutoffHz": {
          "source": "parameter",
          "path": "FilterHighPass",
          "transform": "parseNumeric"
        }
      }
    }

This becomes:

    data.Metadata.Recording.HardwareFilters.BandPassFilter.Enabled
    data.Metadata.Recording.HardwareFilters.BandPassFilter.HighPassCutoffHz

States and auxiliary signals
============================

BCI2000 states can be preserved as additional auxiliary channels in the output
signal file.

Example:

    {
      "name": "ImplantLostSample",
      "source": "state",
      "path": "ImplantLostSample",
      "includeAsAuxiliarySignal": true,
      "includeInEvents": false,
      "decoder": "none",
      "units": "n/a"
    }

Important fields:

name
    Output channel/event name.

source
    Should be `"state"` for BCI2000 states.

path
    State name in `data.States`.

includeAsAuxiliarySignal
    If true, the state is appended to the converted signal as an additional
    channel.

includeInEvents
    If true, the state is also interpreted into BIDS events.

decoder
    Defines the event-decoding strategy.

units
    Physical units for the auxiliary channel.

Export all states
-----------------

The generic BCI2000 profile supports:

    "events": "all"

This expands every available BCI2000 state into an auxiliary channel with:

    includeAsAuxiliarySignal = true
    includeInEvents = false

State transforms
================

Some BCI2000 states store packed numeric values and require a state-specific
transform before export.

Only states explicitly requesting a transform are transformed.

toDouble
    Conventional MATLAB numeric conversion:

        double(values)

typecastSingle
    Reinterprets packed bytes as IEEE-754 single precision:

        typecast(values, "single")

    The result is then converted to MATLAB double for downstream processing.

typecastDouble
    Reinterprets packed bytes as IEEE-754 double precision.

XsensMTwDegrees
    Recovers Xsens MTw orientation values using:

        (state - 2^31) / DataPrescaler

Extension profiles
==================

Extension profiles are optional JSON profiles that add states, transforms,
metadata, or stimulation behavior only when a BCI2000 feature is active.

Examples:

    XsensMTwLogger.json
    StimulusPresentationTask.json
    gEstimFilter.json
    CorTecBIC_OnlineProcessing.json

A base profile references extensions as:

    "extensions": [
      {"profile": "XsensMTwLogger.json"},
      {"profile": "StimulusPresentationTask.json"}
    ]

Extension paths are resolved relative to the main profile file.

Extension activation
--------------------

An extension may define an activation condition.

Numeric example:

    "activation": {
      "source": "parameter",
      "path": "LogXsensMTw",
      "equals": 1
    }

String example:

    "activation": {
      "source": "parameter",
      "path": "ApplicationFilterChain",
      "equals": "StimulusPresentationTask"
    }

Extension state structure
-------------------------

Extension profiles should use `"states"` rather than the main profile's
top-level `"events"` array.

Example:

    {
      "profileName": "StimulusPresentationTask",
      "profileVersion": "0.1.1",
      "activation": {
        "source": "parameter",
        "path": "ApplicationFilterChain",
        "equals": "StimulusPresentationTask"
      },
      "states": [
        {
          "name": "StimulusCode",
          "source": "state",
          "path": "StimulusCode",
          "includeAsAuxiliarySignal": true,
          "includeInEvents": true,
          "decoder": "stateIntervals",
          "units": "n/a"
        }
      ]
    }

Preprocessing
=============

Profiles may specify preprocessing operations that modify the signal used for
export while preserving the original loaded signal.

The class maintains:

    data.Signal
        Original calibrated BCI2000 signal.

    data.ProcessedSignal
        Signal after profile-defined preprocessing. This is used for BIDS export.

Example: CorTec BIC packet-loss correction

    "preprocessing": [
      {
        "function": "maskStateSamples",
        "state": "ImplantLostSample",
        "condition": "nonzero",
        "target": "signal",
        "replacement": "NaN"
      }
    ]

This replaces samples identified by `ImplantLostSample` with NaN in
`ProcessedSignal` while leaving the original `Signal` and state vector intact.

Events
======

States with `"includeInEvents": true` are converted into `*_events.tsv`.

For `stateIntervals`, contiguous non-zero periods are converted into rows with:

    onset
    duration
    trial_type
    value
    sample

The accompanying `*_events.json` describes these columns.

Stimulus presentation
---------------------

The `StimulusPresentationTask` extension typically preserves task-related states
such as:

    PresentationRequested
    PresentationDisplayed
    StimulusCode
    StimulusBegin
    PhaseInSequence

Electrical stimulation
======================

Electrical stimulation is represented separately from generic events.

The BIDS iEEG sidecar is populated with:

    "ElectricalStimulation": true

when an active stimulation profile is enabled.

Actual stimulation periods are written to `events.tsv` using
`electrical_stimulation_<label>` columns.

Stimulation modes
-----------------

The converter currently supports two stimulation configuration modes.

triggerTable
~~~~~~~~~~~~

Used for systems such as CorTec Brain Interchange where a trigger-state value
selects a column from a BCI2000 stimulation-trigger table.

Example:

    "stimulation": {
      "enabled": true,
      "mode": "triggerTable",
      "eventState": "ImplantStimulation",
      "triggerState": "StimulusCode",
      "parametersPath": "parameters.StimulationPulses",
      "triggersPath": "parameters.StimulationTriggers",
      "triggerRow": 1,
      "functionIDsRow": 2
    }

parameterSet
~~~~~~~~~~~~

Used for systems such as BCI2000 `gEstimFilter`, where stimulation configuration
is described by a collection of parameters.

Example:

    "stimulation": {
      "enabled": true,
      "mode": "parameterSet",
      "eventState": "EstimStimulus",
      "triggerState": "StimulusCode",
      "parameterPaths": [
        "Magnitude",
        "PhaseDuration",
        "InterphaseDuration",
        "NumberOfPulses",
        "PulseFrequency"
      ]
    }

Custom stimulation parameter file
---------------------------------

When stimulation is enabled, the converter also writes a custom file:

    <BIDS root>/stimuli/
        sub-<label>[_ses-<label>]_task-<label>[_acq-<label>][_run-<index>]_stimParameters.json

This file is additional to the BIDS specification and preserves the complete
BCI2000 stimulation configuration.

Complex BCI2000 matrix parameters are parsed using:

    parseBCI2000_parameters_values.m

Profile organization examples
=============================

Generic BCI2000
---------------
    BCI2000_Generic_profile.json

Purpose:
    Device-agnostic conversion and export of all BCI2000 states as auxiliary
    channels.

CorTec Brain Interchange
------------------------
    CorTecBIC_profile.json

Purpose:
    CorTec Brain Interchange recordings.

Typical behavior:
    - Manufacturer/model metadata.
    - ImplantLostSample auxiliary state.
    - Lost-sample masking to NaN.
    - Optional Xsens extension.
    - Optional StimulusPresentationTask extension.
    - CorTec stimulation trigger-table handling.

g.HIamp
-------
    gHIamp_profile.json

Purpose:
    g.tec g.HIamp recordings.

Typical behavior:
    - g.HIamp device metadata.
    - g.HIamp reference channels.
    - g.HIamp filter metadata.
    - Channel-unit extraction from SourceChGain.

g.HIamp functional data
-----------------------
    gHIamp_FunctionalData.json

Purpose:
    g.HIamp functional/task recordings.

Typical behavior:
    - g.HIamp base metadata.
    - DigitalInput1 auxiliary state.
    - StimulusPresentationTask extension.

g.HIamp stimulation
-------------------
    gHIamp_Stimulation.json

Purpose:
    g.HIamp recordings using gEstimFilter stimulation.

Typical behavior:
    - g.HIamp base metadata.
    - StimulusPresentationTask extension.
    - gEstimFilter extension.
    - gEstim stimulation parameters.
    - Electrical stimulation events.

Adding a new conversion profile
===============================

Recommended workflow
--------------------

1. Inspect one representative BCI2000 `.dat` file.

2. Record relevant parameter names:

       fieldnames(parameters)

3. Record available states:

       fieldnames(states)

4. Determine:
   - amplifier/source module;
   - modality;
   - sampling-rate parameter;
   - channel-count parameter;
   - channel units;
   - reference configuration;
   - hardware filters;
   - task-related states;
   - optional BCI2000 logger/filter modules;
   - stimulation parameters, if applicable;
   - device-specific preprocessing requirements.

5. Decide whether the new behavior belongs in:
   - a base device profile;
   - an extension profile;
   - a task profile;
   - a stimulation extension.

6. Reuse existing generic transforms and preprocessing functions whenever
   possible.

7. Only modify `BCI2000_data` when the new profile requires behavior that cannot
   be expressed using the existing profile schema.

8. Validate the resulting BIDS dataset with the BIDS Validator.

LLM prompt template for implementing a new profile
==================================================

Use the following prompt together with the current `BCI2000_data.m`, relevant
existing profile examples, and documentation for the new BCI2000 device/module.

--------------------------------------------------------------------------

I am extending a MATLAB BCI2000-to-BIDS converter.

The converter uses `BCI2000_data.m` as a generalized conversion class and JSON
profiles to describe device-specific and task-specific behavior.

Please create a new conversion profile for:

    <DEVICE / BCI2000 MODULE NAME>

BCI2000 documentation:

    <DOCUMENTATION URL>

The recording modality is:

    <iEEG / EEG / other>

Relevant BCI2000 parameters are:

    <LIST PARAMETER NAMES OR PASTE parameter STRUCTURE EXAMPLES>

Relevant BCI2000 states are:

    <LIST STATE NAMES>

The required behavior is:

    - Manufacturer: <...>
    - Model: <...>
    - Sampling frequency parameter: <...>
    - Channel-count parameter: <...>
    - Channel units: <...>
    - Reference parameter: <...>
    - Hardware-filter parameters: <...>
    - States to preserve as auxiliary channels: <...>
    - States to convert to events: <...>
    - Required state transforms: <...>
    - Required preprocessing: <...>
    - Stimulation enabled: <true/false>
    - Stimulation event state: <...>
    - Stimulation trigger state: <...>
    - Stimulation parameter locations: <...>
    - Optional BCI2000 extensions that should be activated: <...>

Please use the existing conversion-profile architecture rather than hard-coding
device-specific logic into `BCI2000_data`.

Requirements:

1. Produce valid JSON.
2. Use a base profile for the acquisition device and extension profiles for
   optional BCI2000 modules whenever appropriate.
3. Use `"states"` inside extension profiles.
4. Use `"events"` in the main profile only for states belonging directly to that
   profile.
5. Reuse existing transforms where possible:
       parseNumeric
       toString
       Datetime
       joinStrings
       extractUnitsFromGain
       toDouble
       typecastSingle
       typecastDouble
       XsensMTwDegrees
6. Use profile-defined preprocessing rather than device-specific MATLAB code
   when possible.
7. For stimulation, use either `"mode": "triggerTable"` or
   `"mode": "parameterSet"` depending on how the BCI2000 module stores
   stimulation configuration.
8. Preserve stimulation configuration in the custom
   `stimuli/*_stimParameters.json` output when stimulation is enabled.
9. Identify any changes genuinely required in `BCI2000_data.m`.
10. Do not introduce additional signal calibration if the BCI2000 data are
    already loaded using `load_bcidat(..., '-calibrated')`.
11. If a packed BCI2000 state requires reinterpretation, use `typecast` only for
    that explicitly specified state.
12. Clearly explain assumptions before implementing behavior that is not
    established by the BCI2000 documentation or supplied data.

Return:
    A. The complete JSON profile.
    B. Any required extension-profile JSON files.
    C. Only the MATLAB changes necessary to support the profile.
    D. A short explanation of how the profile maps BCI2000 data into BIDS.

--------------------------------------------------------------------------

Development principles
======================

Keep the conversion class generic
---------------------------------
Device-specific metadata should normally be expressed in JSON. Add MATLAB logic
only when a genuinely new generic operation is required.

Preserve source information
---------------------------
`Signal`, `States`, and `Parameters` should preserve the source recording.
Signal corrections should operate on `ProcessedSignal`.

Do not recalibrate calibrated recordings
----------------------------------------
When the BCI2000 loader is called with:

    load_bcidat(..., "-calibrated")

the returned signal is already in physical units. Do not apply SourceChGain or
SourceChOffset a second time.

Prefer extension profiles
-------------------------
Optional modules such as Xsens, StimulusPresentationTask, online processing, or
gEstimFilter should be implemented as extension profiles instead of duplicating
their logic across multiple base profiles.

Keep units channel-specific
---------------------------
Signal writers should accept one physical unit per channel so neural channels
and auxiliary channels can coexist correctly.

Example:

    Ch1                 uV
    Ch2                 uV
    MTw1X               degrees
    EstimCurrent        uA
    NormalizerOutput    a.u.

Validate everything
-------------------
The converter should maintain validation messages rather than silently ignoring
missing required metadata. After conversion, validate the resulting dataset with
the official BIDS Validator.

Current limitations / future work
=================================

- BrainVision signal export is not yet fully implemented.
- Additional BCI2000 modules may require new generic transforms.
- More event decoders may be needed for states that are not naturally
  represented as contiguous non-zero intervals.
- Profile inheritance could further reduce duplication between closely related
  base profiles.
- Automated BIDS dataset-level files such as `dataset_description.json`,
  `participants.tsv`, and `scans.tsv` may be expanded further depending on the
  intended release workflow.
