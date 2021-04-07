%
% This is a draft/start of a script to read a BCI2000 data file and write a
% corresponging _xeeg.json file. 
%
% This script is partially a copy from a bids-starter-kit template
% https://github.com/bids-standard/bids-starter-kit. This draft can serve
% as a backbone, but needs to be further developed and turned into a
% function/gui.
%
% 2021



%% 


% which data to load
fileName = 'myData_S000R01.dat';

% where to create BIDS files
bids_rootdir = '';

% set data type: ieeg/eeg
data_type = 'ieeg';

%% load the data and other information

[data,states,params] = load_bcidat(fileName);

%% get basic file info

% get name
bids_sub =  params.SubjectName.Value{1};

% get session
bids_ses = params.SubjectSession.Value{1};

% get run
bids_run = params.SubjectRun.Value{1};

% get task, this should probably give a popup
bids_task = '';

ieeg_json_name = fullfile(bids_rootdir,[ 'sub-' bids_sub ],...
    ['ses-' bids_ses],...
    data_type,...
    ['sub-' bids_sub ...
    '_ses-' bids_ses ...
    '_task-' bids_task ...
    '_run-' bids_run '_' data_type '.json']);


%% Required fields:
ieeg_json.TaskName = ''; % Name of the task (for resting state use the rest
% prefix). No two tasks should have the same name. Task label is derived
% from this field by removing all non alphanumeric ([a-zA-Z0-9]) characters.
% Note this does not have to be a "behavioral task" that subjects perform, but can reflect some
% information about the conditions present when the data was acquired (e.g., "rest" or "sleep").

ieeg_json.SamplingFrequency = params.SamplingRate.NumericValue; %Sampling frequency (in Hz) of all the iEEG channels
% in the recording (e.g., 2400). All other channels should have frequency specified
% as well in the channels.tsv file.

ieeg_json.PowerLineFrequency = ''; %Frequency (in Hz) of the power grid where the
% iEEG recording was done (i.e., 50 or 60).

ieeg_json.SoftwareFilters = 'n/a'; %  List of temporal software filters applied or
% ideally  key:value pairs of pre-applied filters and their parameter values.
% (n/a if none). E.g., "{'HighPass': {'HalfAmplitudeCutOffHz': 1, 'RollOff: '6dB/Octave'}}".

ieeg_json.DCOffsetCorrection = ''; % A description of the method (if any) used to correct for
% a DC offset.If the method used was subtracting the mean value for each channel, use "mean".

ieeg_json.iEEGReference = ''; % General description of the reference scheme used and
% (when applicable) of location of the reference electrode in the raw recordings
% (e.g., "left mastoid", "bipolar", "T01" for electrode with name T01, "intracranial electrode
% on top of a grid, not included with data", "upside down electrode"). If different channels have
% a different reference, this field should have a general description and the channel specific
% reference should be defined in the _channels.tsv file.

%% Recommended fields:

HardwareFilters.HighpassFilter.CutoffFrequency = []; % Contains the high pass hardware filter
% cut off frequency.

HardwareFilters.LowpassFilter.CutoffFrequency = []; % Contains the low pass hardware filter
% cut off frequency.

ieeg_json.HardwareFilters = HardwareFilters; % Cutoff frequencies of high and low pass filter
% are stored in this variable automatically. No further input necessary.

ieeg_json.Manufacturer = ''; % Manufacturer of the amplifier system  (e.g. "TDT, blackrock")

ieeg_json.ManufacturersModelName = params.DeviceIDMaster.Value{1}; % Manufacturer's designation of the

ieeg_json.TaskDescription = params.UserComment.Value{1}; % Longer description of the task.

ieeg_json.Instructions = ''; % Text of the instructions given to participants
% before the recording. This is especially important in context of resting
% state and distinguishing between eyes open and eyes closed paradigms.

ieeg_json.InstitutionName = ''; %  The name of the institution in charge of
% the equipment that produced the composite instances.

ieeg_json.InstitutionAddress = ''; % The address of the institution in charge
% of the equipment that produced the composite instances.

ieeg_json.DeviceSerialNumber = ''; % The serial number of the equipment that
% produced the composite instances. A pseudonym can also be used to prevent
% the equipment from being identifiable, as long as each pseudonym is unique
% within the dataset.

ieeg_json.ECOGChannelCount = ''; % Number of iEEG surface channels included in the recording (e.g. 120)

ieeg_json.SEEGChannelCount = ''; % Number of iEEG depth channels included in the recording (e.g. 8)

ieeg_json.EEGChannelCount = ''; % Number of scalp EEG channels recorded simultaneously (e.g., 21)

ieeg_json.EOGChannelCount = ''; % Number of EOG channels

ieeg_json.ECGChannelCount = ''; % Number of ECG channels

ieeg_json.EMGChannelCount = ''; % Number of EMG channels

ieeg_json.MiscChannelCount = ''; % Number of miscellaneous analog channels for auxiliary  signals

ieeg_json.TriggerChannelCount = ''; % Number of channels for digital (TTL bit level) triggers.

ieeg_json.RecordingDuration = size(data,1)/params.SamplingRate.NumericValue; % Length of the recording in seconds (e.g. 3600)

ieeg_json.RecordingType = 'continuous'; % Defines whether the recording is "continuous" or "epoched"; this latter
% limited to time windows about events of interest (e.g., stimulus presentations, subject responses etc.)

ieeg_json.SubjectArtefactDescription = ''; % Freeform description of the observed
% subject artefact and its possible cause (e.g. door open, nurse walked into room at 2 min,
% "Vagus Nerve Stimulator", non-removable implant, seizure at 10 min).
% If this field is left empty, it will be interpreted as absence of artifacts.

ieeg_json.SoftwareVersions = ''; % Manufacturer's designation of the acquisition software.

ieeg_json.ElectrodeManufacturer = ''; % can be used if all electrodes are of the same manufacturer
%(e.g., AD-TECH, DIXI). If electrodes of different manufacturers are used, please use the corresponding
% table in the _electrodes.tsv file.

ieeg_json.ElectrodeManufacturersModelName = ''; % Specify model name. If different electrode types are used,
%  please use the corresponding table in the _electrodes.tsv file

ieeg_json.iEEGGround = ''; % Description of the location of the ground electrode
% ("placed on right mastoid (M2)").

ieeg_json.iEEGPlacementScheme = ''; % Freeform description of the placement of the iEEG electrodes.
% Left/right/bilateral/depth/surface(e.g. "left frontal grid and bilateral hippocampal depth" or
% "surface strip and STN depth" or "clinical indication bitemporal, bilateral temporal strips and left grid").

ieeg_json.iEEGElectrodeGroups = ''; % Field to describe the way electrodes are grouped
% into strips, grids or depth probes e.g., {'grid1': "10x8 grid on left temporal pole",
% 'strip2': "1x8 electrode strip on xxx"}.


%% Optional fields:

ieeg_json.ElectricalStimulation = ''; % Boolean field to specify if electrical stimulation
% was done during the recording (options are "true" or "false"). Parameters for event-like
% stimulation should be specified in the _events.tsv file (see example underneath).

ieeg_json.ElectricalStimulationParameters = ''; % Free form description of stimulation parameters,
% such as frequency, shape etc. Specific onsets can be specified in the _events.tsv file.
% Specific shapes can be described here in freeform text.


%% write
jsonSaveDir = fileparts(ieeg_json_name);
if ~isdir(jsonSaveDir)
    fprintf('Warning: directory to save json file does not exist, create: %s \n',jsonSaveDir)
end

json_options.indent = '    '; % this just makes the json file look prettier
% when opened in a text editor

try
    jsonwrite(ieeg_json_name,ieeg_json,json_options)
catch
    warning( '%s\n%s\n%s\n%s',...
        'Writing the JSON file seems to have failed.', ...
        'Make sure that the following library is in the matlab/octave path:', ...
        'https://github.com/gllmflndn/JSONio')
end