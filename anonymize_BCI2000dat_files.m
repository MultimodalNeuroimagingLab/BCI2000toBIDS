clearvars; close all; clc
addpath('/Users/lampert.frederik/Documents/MATLAB/mex');

%% Select Data Directory

% Directory containing the BCI2000 .dat recordings.
src_dir = "/Users/lampert.frederik/Documents/Mayo/CorTec/data/clinical/IMG/IMG_d4s2_BCI_overt001";

% Directory where the anonymized data will be saved.
% Leave empty to use src_dir.
out_dir = "/Volumes/MILLER-1/SHARED/CorTec/Data_BIDS/sourcedata/sub-IMG/ses-BCI/ieeg/overt";

%% Settings

% Specify whether files should be renamed.
rename_files = false;

% If rename_files is true, specify the anonymized subject name.
subName = "sub01";

% If out_dir is the same as src_dir and rename_files is false, specify
% whether the original files may be overwritten.
overwrite = false;

% Keep the original year but remove month/day/time by shifting StorageTime
% to January 1st at 00:00:00 of the same year.
shift_storage_time = true;

%% Validate required BCI2000 MATLAB tools

if exist("load_bcidat","file") ~= 3
    error("anonymize_dat_files:MissingLoadBCIDAT", ...
        "load_bcidat was not found on the MATLAB path.");
end

if exist("save_bcidat","file") ~= 3
    error("anonymize_dat_files:MissingSaveBCIDAT", ...
        "save_bcidat was not found on the MATLAB path.");
end

%% Validate source/output directories

if ~isfolder(src_dir)
    error("anonymize_dat_files:InvalidSourceDirectory", ...
        "Source directory does not exist: %s", src_dir);
end

if strlength(out_dir) == 0
    out_dir = src_dir;
end

if ~isfolder(out_dir)
    [success,message] = mkdir(out_dir);
    if ~success
        error("anonymize_dat_files:CreateOutputDirectoryFailed", ...
            "Could not create output directory '%s': %s", ...
            out_dir, message);
    end
end

%% Find all BCI2000 .dat files

files = dir(fullfile(src_dir,"*.dat"));
files = files(~[files.isdir]);

if isempty(files)
    warning("anonymize_dat_files:NoFiles", ...
        "No .dat files were found in %s.", src_dir);
    return
end

%% Prepare log

nFiles = numel(files);

originalName = strings(nFiles,1);
outputName = strings(nFiles,1);
status = strings(nFiles,1);
message = strings(nFiles,1);

%% Process recordings

for f = 1:nFiles

    originalName(f) = string(files(f).name);
    filePathIn = fullfile(string(files(f).folder),originalName(f));

    fprintf("Processing %d of %d: %s\n", ...
        f, nFiles, originalName(f));

    try

        %% Load BCI2000 recording

        % Load the recording in its native BCI2000 representation.
        % Anonymization should modify metadata only and should not
        % unnecessarily alter/recalibrate signal samples.
        [signal,states,parameters] = load_bcidat(char(filePathIn));

        %% -------------------------------------------------------------
        % Anonymize potentially identifying BCI2000 parameters
        % --------------------------------------------------------------

        % StorageTime
        %
        % Remove month/day/time information while preserving the year.
        if shift_storage_time && isfield(parameters,"StorageTime")

            try
                storageValue = getParameterStringValue( parameters.StorageTime);

                if strlength(storageValue) > 0
                    recDate = datetime(storageValue);

                    anonDate = dateshift(recDate,"start","year");

                    % BCI2000 commonly stores StorageTime as a cell string.
                    parameters.StorageTime.Value =  {char(string(anonDate, "yyyy-MM-dd'T'HH:mm:ss"))};

                    if isfield(parameters.StorageTime,"NumericValue")
                        parameters.StorageTime.NumericValue = NaN;
                    end
                end

            catch ME
                warning("anonymize_dat_files:StorageTime", ...
                    "Could not anonymize StorageTime in %s: %s", ...
                    originalName(f), ME.message);
            end
        end

        % Remove local data-directory information.
        parameters = clearParameterValue(parameters, "DataDirectory");

        % Remove startup shell-script/path information.
        parameters = clearParameterValue(parameters, "StartupShellScript");

        % Remove shared-memory holder/path information.
        parameters = clearParameterValue( parameters, "DataFileShm");

        % Remove device identifiers when present.
        parameters = clearParameterValue(parameters, "DeviceIDs");

        parameters = clearParameterValue(parameters, "DeviceIDMaster");

        % % Additional commonly identifying/free-text parameters.
        % parameters = clearParameterValue(parameters, "SubjectName");

        % Remove source file/path-like parameters if they exist.
        parameters = clearParameterValue( parameters, "DataFile");

        parameters = clearParameterValue( parameters, "FileName");

        %% -------------------------------------------------------------
        % Determine anonymized output filename
        % -------------------------------------------------------------

        [~,fileStem] = fileparts(originalName(f));

        if rename_files

            % Extract optional BCI2000 session/run tokens independently.

            sessionToken = regexp(fileStem, ...
                "S\d+", "match", "once");

            runToken = regexp(fileStem,  "R\d+",  "match", "once");

            if isempty(sessionToken)
                sessionToken = "";
            else
                sessionToken = string(sessionToken);
            end

            if isempty(runToken)
                runToken = "";
            else
                runToken = string(runToken);
            end

            % Build anonymized name.
            newStem = subName;

            if strlength(sessionToken) > 0
                newStem = newStem + sessionToken;
            end

            if strlength(runToken) > 0
                newStem = newStem + runToken;
            end

            % If neither token exists, append an index to guarantee
            % deterministic unique filenames.
            if strlength(sessionToken) == 0 && strlength(runToken) == 0
                newStem = newStem + sprintf("R%02d",f);
            end

        else
            newStem = string(fileStem);
        end

        newFileName = newStem + ".dat";
        filePathOut = fullfile(out_dir,newFileName);

        %% Update SubjectName to anonymized identifier

        if isfield(parameters,"SubjectName")
            parameters.SubjectName.Value = {char(newStem)};

            if isfield(parameters.SubjectName,"NumericValue")
                parameters.SubjectName.NumericValue = NaN;
            end
        end

        %% -------------------------------------------------------------
        % Protect source data from accidental overwrite
        % -------------------------------------------------------------

        sameFile = strcmp( ...
            char(java.io.File(filePathIn).getCanonicalPath()), ...
            char(java.io.File(filePathOut).getCanonicalPath()));

        if sameFile && ~overwrite
            error("anonymize_dat_files:OverwriteNotAllowed", ...
                ["Output path is identical to the source file and " ...
                 "overwrite=false: %s"], filePathOut);
        end

        if isfile(filePathOut) && ~sameFile && ~overwrite
            error("anonymize_dat_files:OutputExists", ...
                ["Output file already exists and overwrite=false: %s"], ...
                filePathOut);
        end

        %% Save anonymized BCI2000 file

        save_bcidat( char(filePathOut), signal, states, parameters);
        outputName(f) = newFileName;
        status(f) = "success";
        message(f) = "";

    catch ME

        outputName(f) = "";
        status(f) = "failed";
        message(f) = string(ME.message);

        warning("anonymize_dat_files:FileFailed", ...
            "Failed to anonymize '%s': %s", ...
            originalName(f), ME.message);
    end

end

%% Summary

resultTable = table( ...
    originalName, ...
    outputName, ...
    status, ...
    message, ...
    VariableNames=[ ...
        "OriginalFile", ...
        "OutputFile", ...
        "Status", ...
        "Message"]);

disp(resultTable)

fprintf("\nAnonymization complete.\n");
fprintf("Successful: %d\n",sum(status == "success"));
fprintf("Failed: %d\n",sum(status == "failed"));

%% ------------------------------------------------------------------------
% Local helper functions
% -------------------------------------------------------------------------

function parameters = clearParameterValue(parameters,parameterName)
%CLEARPARAMETERVALUE Clear a BCI2000 parameter when it exists.
%
% Handles optional parameters defensively so the anonymizer can operate
% across recordings produced by different BCI2000 configurations.

    parameterName = char(parameterName);

    if ~isfield(parameters,parameterName)
        return
    end

    parameter = parameters.(parameterName);

    if isfield(parameter,"Value")
        parameter.Value = {''};
    end

    if isfield(parameter,"NumericValue")
        parameter.NumericValue = NaN;
    end

    parameters.(parameterName) = parameter;
end

function value = getParameterStringValue(parameter)
%GETPARAMETERSTRINGVALUE Return a scalar string from a BCI2000 parameter.

    value = "";

    if ~isfield(parameter,"Value") || isempty(parameter.Value)
        return
    end

    rawValue = parameter.Value;

    if iscell(rawValue)
        if isempty(rawValue)
            return
        end
        rawValue = rawValue{1};
    end

    value = strtrim(string(rawValue));
end
