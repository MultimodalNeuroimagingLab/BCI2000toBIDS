clear all; close all; clc
addpath('path/to/BCI2000mex');
%% Specify input and output Files
% Input file path
file_path_in = 'input_XXX.dat';
% Output file path (if same as input will overwirite the data) 
file_path_out = 'output_XXX.dat';

%% Load signal, states, and parameters
[signal, states, parameters, total_samples] = load_bcidat(file_path_in, '-calibrated');
parameters_raw = parameters;

%% Modify the parameters, reduce the signals 
chnls_idx = [1:16, 32]; % e.g. 16 iEEG channels, and groud
reduced_signal = signal(:,chnls_idx );

%% Assign channel Names (Optional)
chNames = arrayfun(@(x) sprintf('ANT%d',x), 1:8,  'UniformOutput', false);
chNames = [chNames, arrayfun(@(x) sprintf('ViM%d',x), 9:16, 'UniformOutput', false)];
chNames = [chNames, {'GND'}];
chNames = chNames(:);   % convert to column cell array

%% Adjust the parameter struct
parameters.SourceCh.NumericValue = numel(chnls_idx);
parameters.SourceCh.Value = {num2str(numel(chnls_idx))};

parameters.SourceChDevices.NumericValue = numel(chnls_idx);
parameters.SourceChDevices.Value = {num2str(numel(chnls_idx))};

parameters.SourceChGain.NumericValue = parameters.SourceChGain.NumericValue(chnls_idx);
parameters.SourceChGain.Value = parameters.SourceChGain.Value(chnls_idx);

parameters.SourceChList.NumericValue = parameters.SourceChList.NumericValue(chnls_idx);
parameters.SourceChList.Value = parameters.SourceChList.Value(chnls_idx);

parameters.SourceChOffset.NumericValue = parameters.SourceChOffset.NumericValue(chnls_idx);
parameters.SourceChOffset.Value = parameters.SourceChOffset.Value(chnls_idx);

parameters.ChannelNames.Value = chNames;
parameters.ChannelNames.NumericValue = 1:numel(chnls_idx);

%% Save
save_bcidat(file_path_out, reduced_signal, states,parameters);