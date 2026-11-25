classdef BCI2000_data < handle
    %BCI2000_DATA Represent one BCI2000 recording and its BIDS mapping state.
    %
    % This initial implementation:
    %   1. Stores one source .dat recording.
    %   2. Preserves the unmodified BCI2000 signal, states, and parameters.
    %   3. Loads a declarative JSON conversion profile.
    %   4. Applies simple parameter mappings to canonical metadata.
    %   5. Initializes standardized channel and event tables.
    %
    % BIDS file writing and advanced state decoding are intentionally left
    % for later implementation.
    %
    % MATLAB release: R2023b or later.

    properties (SetAccess = private)
        % Source file
        FilePath (1,1) string = ""
        FileName (1,1) string = ""

        % Raw BCI2000 content. These properties preserve source information.
        Signal = []
        ProcessedSignal = []
        States (1,1) struct = struct()
        Parameters (1,1) struct = struct()
        Header (1,1) struct = struct()

        % Loaded conversion profile and its path.
        Profile (1,1) struct = struct()
        ExtensionProfiles cell = {}
        ProfilePath (1,1) string = ""

        % Canonical interpretation used by later BIDS writers.
        Metadata (1,1) struct = struct()
        Channels table = table()
        Events table = table()

        % Messages accumulated during loading and profile application.
        Validation table = table()
    end

    properties (Dependent, SetAccess = private)
        NumberOfSamples
        NumberOfChannels
        Duration
    end

    methods
        function obj = BCI2000_data(filePath, profilePath)
            %BCI2000_DATA Construct an object for one BCI2000 recording.
            %
            % obj = BCI2000_data()
            % obj = BCI2000_data(filePath)
            % obj = BCI2000_data(filePath, profilePath)

            obj.initializeDataStructure();

            if nargin >= 1 && strlength(string(filePath)) > 0
                obj.loadRecording(filePath);
            end

            if nargin >= 2 && strlength(string(profilePath)) > 0
                obj.loadProfile(profilePath);
                obj.applyProfile();
                obj.applyProfileExtensions();
                obj.applyPreprocessing();
            end
        end

        function loadRecording(obj, filePath)
            %LOADRECORDING Load one BCI2000 .dat file using load_bcidat.
            %
            % The BCI2000 MATLAB tools must be on the MATLAB path.

            arguments
                obj
                filePath (1,1) string
            end

            if ~isfile(filePath)
                error("BCI2000_data:FileNotFound", ...
                    "BCI2000 file does not exist: %s", filePath);
            end

            [folder, name, extension] = fileparts(filePath);
            if ~strcmpi(extension, ".dat")
                error("BCI2000_data:InvalidExtension", ...
                    "Expected a BCI2000 .dat file, received: %s", extension);
            end

            if exist("load_bcidat", "file") ~= 3
                error("BCI2000_data:MissingBCI2000Tools", ...
                    ["The function load_bcidat was not found on the MATLAB path. " ...
                     "Add the BCI2000 MATLAB tools before loading a recording."]);
            end

            try
                [signal, states, parameters] = load_bcidat(char(filePath),'-calibrated'); % Use the BCI laod_data supported calibration
            catch ME
                throwAsCaller(addCause( ...
                    MException("BCI2000_data:LoadFailed", ...
                    "Could not load BCI2000 file: %s", filePath), ME));
            end

            obj.FilePath = string(filePath);
            obj.FileName = string(name + extension);
            obj.Signal = signal;
            obj.ProcessedSignal = obj.Signal;
            obj.States = states;
            obj.Parameters = parameters;
            obj.Header = struct( ...
                "SourceFolder", string(folder), ...
                "LoadedAt", datetime("now", "TimeZone", "local"));

            obj.addValidation("info", "Source", ...
                "Recording loaded successfully.", "loadRecording");
        end

        function loadProfile(obj, profilePath)
            %LOADPROFILE Read and validate a JSON conversion profile.

            arguments
                obj
                profilePath (1,1) string
            end

            if ~isfile(profilePath)
                error("BCI2000_data:ProfileNotFound", ...
                    "Conversion profile does not exist: %s", profilePath);
            end

            try
                profileText = fileread(profilePath);
                profile = jsondecode(profileText);
            catch ME
                throwAsCaller(addCause( ...
                    MException("BCI2000_data:InvalidProfileJSON", ...
                    "Could not decode conversion profile: %s", profilePath), ME));
            end

            obj.validateProfileStructure(profile);

            obj.Profile = profile;
            obj.ProfilePath = profilePath;

            obj.addValidation("info", "Profile", ...
                "Conversion profile loaded successfully.", "loadProfile");
        end

        function applyProfile(obj)
            %APPLYPROFILE Map source parameters into canonical metadata.
            %
            % The initial implementation supports:
            %   source = "parameter"
            %   source = "constant"
            %   aliases
            %   default
            %   required
            %   transforms:
            %       identity
            %       toDouble
            %       toString
            %       parseNumeric
            %       Datetime
            %
            % More advanced transforms and event decoders can be added
            % without changing the public class interface.

            obj.assertRecordingLoaded();
            obj.assertProfileLoaded();

            obj.Metadata.Profile = struct( ...
                "Name", string(obj.Profile.profileName), ...
                "Version", string(obj.Profile.profileVersion), ...
                "Path", obj.ProfilePath);

            if isfield(obj.Profile, "metadata")
                sections = fieldnames(obj.Profile.metadata);

                for sectionIndex = 1:numel(sections)
                    sectionName = sections{sectionIndex};
                    mappings = obj.Profile.metadata.(sectionName);
                    mappingNames = fieldnames(mappings);

                    if ~isfield(obj.Metadata, sectionName)
                        obj.Metadata.(sectionName) = struct();
                    end

                    for mappingIndex = 1:numel(mappingNames)
                        targetName = mappingNames{mappingIndex};
                        node = mappings.(targetName);

                        [value, found] = obj.evaluateMappingNode( ...
                            node, sectionName + "." + targetName);

                        if found
                            obj.Metadata.(sectionName).(targetName) = value;
                        end
                    end
                end
            end

            obj.buildChannelTable();

            % Event decoding is intentionally not implemented yet.
            % The profile is loaded now so the next development step can
            % add profile-driven state-to-event decoders.
        end

        function setBIDSContext(obj, subjectID, sessionID, taskName)
            %SETBIDSCONTEXT Set BIDS entities supplied by the GUI.
            %
            % This method keeps canonical metadata private while allowing
            % the user interface to provide dataset-specific entities that
            % are not normally stored in the source BCI2000 recording.

            arguments
                obj
                subjectID (1,1) string = ""
                sessionID (1,1) string = ""
                taskName (1,1) string = ""
            end

            subjectID = regexprep(subjectID, "^sub-", "", "ignorecase");
            sessionID = regexprep(sessionID, "^ses-", "", "ignorecase");

            obj.Metadata.Subject.ID = subjectID;
            obj.Metadata.Session.ID = sessionID;
            obj.Metadata.Task.Name = taskName;
        end

        function outputPath = convert2BIDS(obj, outputName, options)
            %CONVERT2BIDS Export the recording signal using a BIDS-compatible
            % electrophysiology file format selected from OUTPUTNAME.
            %
            % outputPath = obj.convert2BIDS(outputName)
            % outputPath = obj.convert2BIDS(outputName, Overwrite=true)
            %
            % The BCI2000_data class performs only format-independent
            % preparation. Format-specific signal writing is delegated to
            % external converter functions. This keeps future EDF and
            % BrainVision support independent of the class implementation.
            %
            % After successful signal export, an accompanying BIDS
            % modality sidecar JSON is created from canonical metadata.
            %
            % Currently supported:
            %   *.mefd  -> dat2mef
            %   *.edf   -> dat2edf
            %
            % Reserved for future implementation:
            %   *.vhdr  -> dat2brainvision

            arguments
                obj
                outputName (1,1) string
                options.Overwrite (1,1) logical = false
            end

            obj.assertRecordingLoaded();

            if strlength(outputName) == 0
                error("BCI2000_data:InvalidOutputName", ...
                    "An output file name must be specified.");
            end

            [outputFolder, baseName, extension] = fileparts(outputName);
            extension = lower(string(extension));

            if strlength(extension) == 0
                error("BCI2000_data:MissingOutputExtension " + ...
                    "The output name must contain a supported extension " + ...
                     "so the signal writer can be selected.");
            end

            if strlength(outputFolder) == 0
                outputFolder = string(pwd);
            elseif ~isfolder(outputFolder)
                [created, message] = mkdir(outputFolder);
                if ~created
                    error("BCI2000_data:OutputDirectoryCreationFailed", ...
                        "Could not create output directory '%s': %s", ...
                        outputFolder, message);
                end
            end

            outputPath = fullfile(outputFolder, baseName + extension);

            switch extension
                case ".mefd"
                    signal = obj.ProcessedSignal;
                    fs = obj.getSamplingFrequency();
                    channelNames = obj.getExportChannelNames();
                    units = obj.getExportUnits();
                    startUutc = obj.getRecordingStartUutc();
                    
                    [auxSignal, auxNames, auxUnits] = ...
                        obj.getAuxiliaryStateSignals();

                    if ~isempty(auxSignal)
                        signal = [signal, auxSignal];
                        channelNames = [channelNames; auxNames];
                        units = [units; auxUnits];
                    end

                    dat2mef(signal, outputPath, channelNames, fs, startUutc, ...
                        Overwrite=options.Overwrite, Units=units);

                case ".edf"
                    signal = obj.ProcessedSignal;
                    fs = obj.getSamplingFrequency();
                    channelNames = obj.getExportChannelNames();
                    units = obj.getExportUnits();
                    recordingTime = obj.getRecordingStartTime();

                    [auxSignal, auxNames, auxUnits] = ...
                        obj.getAuxiliaryStateSignals();
                    if ~isempty(auxSignal)
                        signal = [signal, auxSignal];
                        channelNames = [channelNames; auxNames];
                        units = [units; auxUnits];
                    end

                    dat2edf(signal, outputPath, channelNames, fs, ...
                        recordingTime, Overwrite=options.Overwrite, ...
                        Units=units);

                case {".vhdr", ".eeg", ".vmrk"}
                    error("BCI2000_data:FormatNotImplemented", ...
                        "BrainVision export is reserved in convert2BIDS " +...
                         "but has not been implemented yet. Add an external " +...
                         "dat2brainvision converter to enable it.");

                otherwise
                    error("BCI2000_data:UnsupportedOutputFormat", ...
                        "Unsupported output extension '%s'.", extension);
            end

            % Write the BIDS modality sidecar after the signal export has
            % completed successfully. At present this class implements the
            % iEEG sidecar. Additional modality-specific builders may be
            % added later without changing the external signal writers.
            sidecarPath = obj.writeBIDSSidecar( ...
                outputFolder, baseName, options.Overwrite);

            eventsPath = obj.writeBIDSEvents( ...
                outputFolder, baseName, options.Overwrite);

            stimParametersPath = obj.writeStimulationParameters( ...
                outputFolder, baseName, options.Overwrite);

            obj.addValidation("info", "BIDS.SignalFile", ...
                "Signal exported to " + outputPath + ".", "convert2BIDS");

            obj.addValidation("info", "BIDS.SidecarJSON", ...
                "Sidecar exported to " + sidecarPath + ".", "convert2BIDS");

            if strlength(eventsPath) > 0
                obj.addValidation("info", "BIDS.EventsTSV", ...
                    "Events exported to " + eventsPath + ".", "convert2BIDS");
            end

            if strlength(stimParametersPath) > 0
                obj.addValidation("info", "BCI2000.StimulationParameters", ...
                    "Stimulation parameters exported to " + ...
                    stimParametersPath + ".", "convert2BIDS");
            end
        end

        function applyProfileExtensions(obj)
            %APPLYPROFILEEXTENSIONS Load extension profiles declared by the
            % primary conversion profile.
            %
            % Extension paths are resolved relative to the primary profile file.

            if isempty(fieldnames(obj.Profile)) || ...
                    ~isfield(obj.Profile, "extensions") || ...
                    isempty(obj.Profile.extensions)
                return
            end

            extensions = obj.Profile.extensions;

            if iscell(extensions)
                extensions = [extensions{:}];
            end

            if ~isstruct(extensions)
                error("BCI2000_data:InvalidExtensions", ...
                    "Profile extensions must be an array of objects.");
            end

            profileFolder = fileparts(obj.ProfilePath);

            for extensionIdx = 1:numel(extensions)

                extension = extensions(extensionIdx);

                if ~isfield(extension, "profile")
                    error("BCI2000_data:InvalidExtension", ...
                        "Each extension entry must define a profile.");
                end

                extensionPath = string(extension.profile);

                % Relative extension paths are interpreted relative to the
                % directory containing the primary profile.
                if ~isfile(extensionPath)
                    extensionPath = fullfile( ...
                        profileFolder, extensionPath);
                end

                if ~isfile(extensionPath)
                    error("BCI2000_data:ExtensionProfileNotFound", ...
                        "Extension profile does not exist: %s", ...
                        extensionPath);
                end

                try
                    extensionProfile = jsondecode(fileread(extensionPath));
                catch ME
                    throwAsCaller(addCause( ...
                        MException("BCI2000_data:InvalidExtensionProfileJSON", ...
                        "Could not decode extension profile: %s", profilePath), ME));
                end

                requiredFields = ["profileName", "profileVersion", "activation"];
                for fieldName = requiredFields
                    if ~isfield(extensionProfile, fieldName)
                        error("BCI2000_data:InvalidExtensionProfile", +...
                            "Extension profile is missing required field '%s'.", +...
                            fieldName);
                    end
                end

                if obj.isExtensionProfileActive(extensionProfile)
                    obj.ExtensionProfiles{end+1} = extensionProfile;

                    obj.addValidation("info", ...
                        "ExtensionProfile." + string(extensionProfile.profileName), ...
                        "Extension profile activated.", ...
                        "applyExtensionProfile");
                else
                    obj.addValidation("info", ...
                        "ExtensionProfile." + string(extensionProfile.profileName), ...
                        "Extension profile condition was not met; profile skipped.", ...
                        "applyExtensionProfile");
                end
            end
        end

        function applyPreprocessing(obj)
            %APPLYPREPROCESSING Apply profile-defined preprocessing steps.
            %
            % The original calibrated signal in obj.Signal is never modified.
            % All preprocessing operates on obj.ProcessedSignal, which is
            % subsequently used for BIDS export.

            obj.ProcessedSignal = obj.Signal;

            if isempty(fieldnames(obj.Profile)) || ...
                    ~isfield(obj.Profile, "preprocessing") || ...
                    isempty(obj.Profile.preprocessing)
                return
            end

            rules = obj.Profile.preprocessing;
            if iscell(rules)
                rules = [rules{:}];
            end

            if ~isstruct(rules)
                error("BCI2000_data:InvalidPreprocessingRules", ...
                    "Profile preprocessing must be an array of objects.");
            end

            for ruleIndex = 1:numel(rules)
                rule = rules(ruleIndex);

                if ~isfield(rule, "function")
                    error("BCI2000_data:InvalidPreprocessingRule", ...
                        "Each preprocessing rule must define a function.");
                end

                switch lower(string(rule.function))
                    case "maskstatesamples"
                        obj.maskStateSamples(rule);

                    otherwise
                        error("BCI2000_data:UnknownPreprocessingFunction", ...
                            "Unknown preprocessing function '%s'.", ...
                            string(rule.function));
                end
            end
        end

        function value = get.NumberOfSamples(obj)
            if isempty(obj.Signal)
                value = 0;
            else
                value = size(obj.Signal, 1);
            end
        end

        function value = get.NumberOfChannels(obj)
            if isempty(obj.Signal)
                value = 0;
            else
                value = size(obj.Signal, 2);
            end
        end

        function value = get.Duration(obj)
            value = seconds(NaN);

            if obj.NumberOfSamples == 0
                return
            end

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "SamplingFrequency")
                fs = double(obj.Metadata.Recording.SamplingFrequency);
                if isfinite(fs) && fs > 0
                    value = seconds(obj.NumberOfSamples / fs);
                end
            end
        end
    end

    methods (Access = private)

        function sidecarPath = writeBIDSSidecar(obj, outputFolder, baseName, overwrite)
            %WRITEBIDSSIDECAR Write the BIDS modality sidecar JSON.
            %
            % The current implementation targets BIDS iEEG. The sidecar
            % uses the same BIDS entity prefix and "_ieeg" suffix as the
            % signal recording. For example:
            %
            %   sub-01_task-rest_ieeg.mefd
            %   sub-01_task-rest_ieeg.json

            modality = "ieeg";

            if isfield(obj.Profile, "modality")
                profileModality = lower(string(obj.Profile.modality));
                if any(profileModality == ["ieeg", "ecog", "seeg"])
                    modality = "ieeg";
                elseif profileModality == "eeg"
                    error("BCI2000_data:EEGSidecarNotImplemented", ...
                        ["The selected profile specifies EEG. EEG sidecar " ...
                         "generation is not implemented yet."]);
                elseif profileModality ~= "n/a" && strlength(profileModality) > 0
                    error("BCI2000_data:UnsupportedBIDSModality", ...
                        "Unsupported BIDS modality '%s'.", profileModality);
                end
            end

            switch modality
                case "ieeg"
                    sidecar = obj.buildIEEGSidecar(baseName);
                    sidecarPath = fullfile(outputFolder, baseName + ".json");

                otherwise
                    error("BCI2000_data:UnsupportedBIDSModality", ...
                        "Unsupported BIDS sidecar modality '%s'.", modality);
            end

            if isfile(sidecarPath) && ~overwrite
                error("BCI2000_data:SidecarExists", ...
                    ["BIDS sidecar already exists: %s. Set Overwrite=true " ...
                     "to replace it."], sidecarPath);
            end

            jsonText = jsonencode(sidecar, PrettyPrint=true);

            fileID = fopen(sidecarPath, "w");
            if fileID == -1
                error("BCI2000_data:SidecarWriteFailed", ...
                    "Could not open BIDS sidecar for writing: %s", ...
                    sidecarPath);
            end

            cleanup = onCleanup(@() fclose(fileID));
            fprintf(fileID, "%s\n", jsonText);
        end

        function sidecar = buildIEEGSidecar(obj, baseName)
            %BUILDIEEGSIDECAR Build metadata for *_ieeg.json.
            %
            % Required BIDS iEEG fields:
            %   TaskName
            %   iEEGReference
            %   SamplingFrequency
            %   PowerLineFrequency
            %   SoftwareFilters
            %
            % Recommended fields are added whenever they can be derived
            % reliably from canonical metadata.

            sidecar = struct();

            %% Task information (required)
            sidecar.TaskName = obj.getBIDSTaskName(baseName);

            %% Required iEEG metadata
            sidecar.iEEGReference = obj.getMetadataOrDefault( ...
                "Recording", "Reference", "n/a");

            sidecar.SamplingFrequency = obj.getSamplingFrequency();

            powerLineFrequency = obj.getMetadataOrDefault( ...
                "Recording", "PowerLineFrequency", "n/a");
            if isnumeric(powerLineFrequency)
                if isscalar(powerLineFrequency) && isfinite(powerLineFrequency)
                    sidecar.PowerLineFrequency = double(powerLineFrequency);
                else
                    sidecar.PowerLineFrequency = "n/a";
                end
            else
                parsedPowerLine = str2double(string(powerLineFrequency));
                if isfinite(parsedPowerLine)
                    sidecar.PowerLineFrequency = parsedPowerLine;
                else
                    sidecar.PowerLineFrequency = "n/a";
                end
            end

            softwareFilters = obj.getMetadataOrDefault( ...
                "Recording", "SoftwareFilters", "n/a");
            if isstruct(softwareFilters)
                sidecar.SoftwareFilters = softwareFilters;
            else
                sidecar.SoftwareFilters = string(softwareFilters);
            end

            hardwareFilters = obj.getMetadataOrDefault( ...
                "Recording", "HardwareFilters", "n/a");
            if isstruct(hardwareFilters)
                sidecar.HardwareFilters = hardwareFilters;
            else
                sidecar.HardwareFilters = string(hardwareFilters);
            end

            %% Recommended hardware information
            manufacturer = obj.getMetadataOrDefault( ...
                "Device", "Manufacturer", "");
            if strlength(string(manufacturer)) > 0
                sidecar.Manufacturer = string(manufacturer);
            end

            model = obj.getMetadataOrDefault( ...
                "Device", "Model", "");
            if strlength(string(model)) > 0
                sidecar.ManufacturersModelName = string(model);
            end

            softwareVersion = obj.getMetadataOrDefault( ...
                "Device", "SoftwareVersions", "");
            if strlength(string(softwareVersion)) > 0
                sidecar.SoftwareVersions = string(softwareVersion);
            end

            serialNumber = obj.getMetadataOrDefault( ...
                "Device", "SerialNumber", "");
            if strlength(string(serialNumber)) > 0
                sidecar.DeviceSerialNumber = string(serialNumber);
            end

            %% Recommended recording information
            sidecar.RecordingDuration = obj.NumberOfSamples / ...
                obj.getSamplingFrequency();

            recordingType = lower(string(obj.getMetadataOrDefault( ...
                "Recording", "RecordingType", "continuous")));

            if ~any(recordingType == ["continuous", "epoched", "discontinuous"])
                obj.addValidation("warning", "Recording.RecordingType", ...
                    "Invalid RecordingType; using 'continuous' in sidecar.", ...
                    "buildIEEGSidecar");
                recordingType = "continuous";
            end
            sidecar.RecordingType = recordingType;

            % Channel counts are recommended in BIDS. Count known channel
            % types directly from the canonical Channels table.
            channelCounts = obj.getBIDSChannelCounts();
            countFields = fieldnames(channelCounts);
            for fieldIndex = 1:numel(countFields)
                fieldName = countFields{fieldIndex};
                sidecar.(fieldName) = channelCounts.(fieldName);
            end

            %% Optional/recommended iEEG descriptions when supplied by profile
            optionalTextFields = {
                "Ground",           "iEEGGround";
                "PlacementScheme",  "iEEGPlacementScheme";
                "ElectrodeGroups",  "iEEGElectrodeGroups"
            };

            for fieldIndex = 1:size(optionalTextFields, 1)
                sourceField = optionalTextFields{fieldIndex,1};
                bidsField = optionalTextFields{fieldIndex,2};
                value = obj.getMetadataOrDefault( ...
                    "Recording", sourceField, "");

                if strlength(string(value)) > 0
                    sidecar.(bidsField) = string(value);
                end
            end

            % BIDS iEEG ElectricalStimulation is controlled by the
            % profile-level stimulation.enabled flag when present.
            stimulationConfig = obj.getStimulationConfig();

            if stimulationConfig.enabled
                sidecar.ElectricalStimulation = true;
            else
                electricalStimulation = obj.getMetadataOrDefault( ...
                    "Recording", "ElectricalStimulation", []);

                if ~isempty(electricalStimulation)
                    sidecar.ElectricalStimulation = ...
                        logical(electricalStimulation);
                end
            end

            %% BCI2000 conversion provenance
            % Non-standard BIDS metadata are grouped under a dedicated
            % namespace to keep standard BIDS fields separate.
            sidecar.BCI2000 = obj.buildBCI2000Provenance();
        end

        function provenance = buildBCI2000Provenance(obj)
            %BUILDBCI2000PROVENANCE Build converter-specific provenance
            % metadata for inclusion in the BIDS sidecar JSON.

            provenance = struct();

            provenance.OriginalFile = obj.FileName;

            % Store the intended source-data location relative to the BIDS
            % dataset root rather than the original absolute filesystem path.
            provenance.OriginalPath = obj.getSourceDataRelativePath();

            if ~isempty(fieldnames(obj.Profile))
                if isfield(obj.Profile, "profileName")
                    provenance.ConversionProfile = ...
                        string(obj.Profile.profileName);
                end

                if isfield(obj.Profile, "profileVersion")
                    provenance.ProfileVersion = ...
                        string(obj.Profile.profileVersion);
                end
            end

            sourceModule = obj.getMetadataOrDefault( ...
                "Device", "SourceModule", "");
            if strlength(string(sourceModule)) > 0
                provenance.SourceModule = string(sourceModule);
            end

            startTime = obj.getMetadataOrDefault( ...
                "Recording", "StartTime", []);

            if ~isempty(startTime)
                if isdatetime(startTime)
                    provenance.StorageTime = string(startTime, ...
                        "yyyy-MM-dd'T'HH:mm:ss.SSS");
                else
                    provenance.StorageTime = string(startTime);
                end
            end

            if isfield(obj.Profile, "preprocessing") && ...
                    ~isempty(obj.Profile.preprocessing)
                provenance.Preprocessing = obj.Profile.preprocessing;
            end

            provenance.Converter = "BCI2000_to_BIDS";
        end

        function taskName = getBIDSTaskName(obj, baseName)
            %GETBIDSTASKNAME Get TaskName from canonical metadata, falling
            % back to the task entity present in the BIDS output filename.

            taskName = "";

            if isfield(obj.Metadata, "Task") && ...
                    isfield(obj.Metadata.Task, "Name")
                taskName = string(obj.Metadata.Task.Name);
            end

            if strlength(taskName) == 0 || ismissing(taskName)
                token = regexp(char(baseName), ...
                    '(?:^|_)task-([A-Za-z0-9+]+)(?:_|$)', ...
                    'tokens', 'once');
                if ~isempty(token)
                    taskName = string(token{1});
                end
            end

            if strlength(taskName) == 0 || ismissing(taskName)
                error("BCI2000_data:MissingTaskName BIDS iEEG requires TaskName. " + ...
                    "Set Metadata.Task.Name or include a task-<label> entity in outputName.");
            end
        end

        function relativePath = getSourceDataRelativePath(obj)
            %GETSOURCEDATARELATIVEPATH Return the BIDS-relative location of
            % the original BCI2000 DAT file under sourcedata/.
            %
            % Examples:
            %   sourcedata/sub-c01/ses-postop/ieeg/recording.dat
            %   sourcedata/sub-c01/ieeg/recording.dat
            %   sourcedata/ieeg/recording.dat
            %
            % Subject/session identifiers may be stored either with or
            % without their BIDS prefixes. Prefixes are normalized here.

            subject = string(obj.getMetadataOrDefault( ...
                "Subject", "ID", ""));
            session = string(obj.getMetadataOrDefault( ...
                "Session", "ID", ""));

            if strlength(subject) > 0
                subject = regexprep(subject, "^sub-", "", "ignorecase");
            end

            if strlength(session) > 0
                session = regexprep(session, "^ses-", "", "ignorecase");
            end

            pathParts = "sourcedata";

            if strlength(subject) > 0
                pathParts(end+1) = "sub-" + subject;
            end

            if strlength(session) > 0
                pathParts(end+1) = "ses-" + session;
            end

            % The current converter targets iEEG. This can later be
            % generalized from the selected BIDS modality/profile.
            pathParts(end+1) = "ieeg";
            pathParts(end+1) = obj.FileName;

            relativePath = strjoin(pathParts, "/");
        end

        function value = getMetadataOrDefault(obj, section, field, defaultValue)
            %GETMETADATAORDEFAULT Read one canonical metadata field.

            value = defaultValue;

            if isfield(obj.Metadata, section) && ...
                    isfield(obj.Metadata.(section), field)
                candidate = obj.Metadata.(section).(field);

                if ~isempty(candidate)
                    value = candidate;
                end
            end
        end

        function counts = getBIDSChannelCounts(obj)
            %GETBIDSCHANNELCOUNTS Count standard electrophysiology types.

            counts = struct( ...
                "ECOGChannelCount", 0, ...
                "SEEGChannelCount", 0, ...
                "EEGChannelCount", 0, ...
                "EOGChannelCount", 0, ...
                "ECGChannelCount", 0, ...
                "EMGChannelCount", 0, ...
                "MiscChannelCount", 0, ...
                "TriggerChannelCount", 0);

            if height(obj.Channels) ~= obj.NumberOfChannels || ...
                    ~ismember("type", string(obj.Channels.Properties.VariableNames))
                counts.MiscChannelCount = obj.NumberOfChannels;
                return
            end

            channelTypes = upper(string(obj.Channels.type(:)));

            counts.ECOGChannelCount = sum(channelTypes == "ECOG");
            counts.SEEGChannelCount = sum(channelTypes == "SEEG");
            counts.EEGChannelCount = sum(channelTypes == "EEG");
            counts.EOGChannelCount = sum(channelTypes == "EOG");
            counts.ECGChannelCount = sum(channelTypes == "ECG");
            counts.EMGChannelCount = sum(channelTypes == "EMG");
            counts.TriggerChannelCount = sum(channelTypes == "TRIG");

            recognized = ismember(channelTypes, ...
                ["ECOG", "SEEG", "EEG", "EOG", "ECG", "EMG", "TRIG"]);
            counts.MiscChannelCount = sum(~recognized);
        end

        function maskStateSamples(obj, rule)
            %MASKSTATESAMPLES Replace selected signal samples according to
            % a BCI2000 state while preserving the original state vector.

            if ~isfield(rule, "state")
                error("BCI2000_data:InvalidPreprocessingRule", ...
                    "maskStateSamples requires a state field.");
            end

            [stateValues, found] = obj.getStateValue(string(rule.state));
            if ~found
                error("BCI2000_data:MissingPreprocessingState", ...
                    "State '%s' was not found.", string(rule.state));
            end

            stateValues = double(stateValues(:));

            if numel(stateValues) ~= obj.NumberOfSamples
                error("BCI2000_data:StateLengthMismatch", ...
                    ["State '%s' contains %d samples but the signal " ...
                     "contains %d samples."], ...
                    string(rule.state), numel(stateValues), ...
                    obj.NumberOfSamples);
            end

            condition = "nonzero";
            if isfield(rule, "condition")
                condition = lower(string(rule.condition));
            end

            switch condition
                case "nonzero"
                    mask = stateValues ~= 0;

                case "positive"
                    mask = stateValues > 0;

                case "negative"
                    mask = stateValues < 0;

                otherwise
                    error("BCI2000_data:UnsupportedMaskCondition", ...
                        "Unsupported preprocessing condition '%s'.", ...
                        condition);
            end

            replacement = "nan";
            if isfield(rule, "replacement")
                replacement = lower(string(rule.replacement));
            end

            switch replacement
                case "nan"
                    obj.ProcessedSignal(mask, :) = NaN;

                case "zero"
                    obj.ProcessedSignal(mask, :) = 0;

                otherwise
                    error("BCI2000_data:UnsupportedReplacement", ...
                        "Unsupported preprocessing replacement '%s'.", ...
                        replacement);
            end

            obj.addValidation("info", string(rule.state), ...
                sprintf("Preprocessing modified %d signal samples.", sum(mask)), ...
                "applyPreprocessing");
        end

        function active = isExtensionProfileActive(obj, profile)
            %ISEXTENSIONPROFILEACTIVE Evaluate a simple parameter condition.
            %
            % Supports numeric or string equality:
            %   "equals": 1
            %   "equals": "CorTecADC"

            activation = profile.activation;

            if ~isfield(activation, "source") || ...
                    lower(string(activation.source)) ~= "parameter" || ...
                    ~isfield(activation, "path")
                error("BCI2000_data:InvalidExtensionActivation", ...
                    ["Extension activation must define source='parameter' " ...
                     "and a parameter path."]);
            end

            if ~isfield(activation, "equals")
                error("BCI2000_data:InvalidExtensionActivation", ...
                    "Extension activation must define an equals value.");
            end

            expectedValue = activation.equals;

            if isnumeric(expectedValue) || islogical(expectedValue)
                [value, found] = obj.getParameterNumericValue( ...
                    string(activation.path));

                if ~found || ~isscalar(value)
                    active = false;
                    return
                end

                active = double(value) == double(expectedValue);

            else
                [value, found] = obj.getParameterValue( ...
                    string(activation.path));

                if ~found
                    active = false;
                    return
                end

                if iscell(value) && numel(value) == 1
                    value = value{1};
                end

                active = any(strcmpi(strtrim(string(value)), ...
                    strtrim(string(expectedValue))),'all');
            end
        end

        function values = applyStateTransform(obj, transformName, values, rule)
            %APPLYSTATETRANSFORM Apply a registered auxiliary-state transform.

            switch lower(transformName)
                case "todouble"
                    % Conventional numeric conversion.
                    values = double(values);

                case "typecastsingle"
                    % Reinterpret packed BCI2000 state bytes as IEEE-754
                    % single precision, then convert to MATLAB double for
                    % downstream processing/export.
                    values = typecast(values, "single");
                    values = double(values(:));

                case "typecastdouble"
                    % Reinterpret packed BCI2000 state bytes as IEEE-754
                    % double precision, then return a column vector.
                    values = typecast(values, "double");
                    values = values(:);

                case "xsensmtwdegrees"
                    prescalerPath = "DataPrescaler";
                    if isfield(rule, "prescalerParameter")
                        prescalerPath = string(rule.prescalerParameter);
                    end

                    [prescaler, found] = ...
                        obj.getParameterNumericValue(prescalerPath);

                    if ~found || ~isscalar(prescaler) || ...
                            ~isfinite(prescaler) || prescaler == 0
                        error("BCI2000_data:InvalidXsensPrescaler", ...
                            ["Xsens state conversion requires a non-zero " ...
                             "DataPrescaler parameter."]);
                    end

                    values = (double(values) - 2^31) ./ double(prescaler);

                otherwise
                    error("BCI2000_data:UnknownStateTransform", ...
                        "Unknown state transform '%s'.", transformName);
            end
        end

        function [auxSignal, auxNames, auxUnits] = getAuxiliaryStateSignals(obj)
            %GETAUXILIARYSTATESIGNALS Return profile-selected BCI2000
            % states as sample-synchronous auxiliary channels.
            %
            % Units are returned per auxiliary channel. A rule may specify
            % "units" in the JSON profile; otherwise "n/a" is used.

            auxSignal = [];
            auxNames = strings(0,1);
            auxUnits = strings(0,1);

            rules = obj.getConfiguredStateRules();

            for ruleIndex = 1:numel(rules)
                rule = rules(ruleIndex);

                if ~isfield(rule, "includeAsAuxiliarySignal") || ...
                        ~logical(rule.includeAsAuxiliarySignal)
                    continue
                end

                [stateValues, found] = obj.getStateValue(string(rule.path));
                if ~found
                    obj.addValidation("warning", string(rule.path), ...
                        "Configured auxiliary state was not found.", ...
                        "getAuxiliaryStateSignals");
                    continue
                end

                % Apply the transform to the source state's original data
                % type. This is required for transforms such as typecast to
                % double, where converting numerically beforehand would
                % destroy the packed representation.
                stateValues = stateValues(:);
                if isfield(rule, "transform") && ...
                        ~isempty(rule.transform) && ...
                        strlength(string(rule.transform)) > 0
                    stateValues = obj.applyStateTransform( ...
                        string(rule.transform), stateValues, rule);
                else
                    stateValues = double(stateValues);
                end

                stateValues = double(stateValues(:));

                if numel(stateValues) ~= obj.NumberOfSamples
                    error("BCI2000_data:StateLengthMismatch", ...
                        "State '%s' length does not match signal length.", ...
                        string(rule.path));
                end

                auxSignal(:,end+1) = stateValues; %#ok<AGROW>

                if isfield(rule, "name") && ...
                        ~isempty(rule.name) && ...
                        strlength(string(rule.name)) > 0
                    auxNames(end+1,1) = string(rule.name); %#ok<AGROW>
                else
                    auxNames(end+1,1) = string(rule.path); %#ok<AGROW>
                end

                if isfield(rule, "units") && ...
                        ~isempty(rule.units) && ...
                        strlength(string(rule.units)) > 0
                    auxUnits(end+1,1) = string(rule.units); %#ok<AGROW>
                else
                    auxUnits(end+1,1) = "n/a"; %#ok<AGROW>
                end
            end
        end

        function eventsPath = writeBIDSEvents(obj, outputFolder, baseName, overwrite)
            %WRITEBIDSEVENTS Write BIDS *_events.tsv and *_events.json.

            eventsPath = "";
            events = obj.buildEventsTable();
            obj.Events = events;

            if height(events) == 0
                return
            end

            eventsBaseName = regexprep(string(baseName), ...
                "_(ieeg|eeg|meg)$", "", "ignorecase");

            eventsPath = fullfile(outputFolder, ...
                eventsBaseName + "_events.tsv");
            eventsJsonPath = fullfile(outputFolder, ...
                eventsBaseName + "_events.json");

            if ~overwrite
                if isfile(eventsPath)
                    error("BCI2000_data:EventsFileExists", ...
                        "Events file already exists: %s", eventsPath);
                end
                if isfile(eventsJsonPath)
                    error("BCI2000_data:EventsJSONExists", ...
                        "Events JSON already exists: %s", eventsJsonPath);
                end
            end

            writetable(events, eventsPath, ...
                "FileType", "text", "Delimiter", "\t");

            metadata = obj.buildEventsSidecar();
            jsonText = jsonencode(metadata, PrettyPrint=true);

            fileID = fopen(eventsJsonPath, "w");
            if fileID == -1
                error("BCI2000_data:EventsJSONWriteFailed", ...
                    "Could not open events JSON for writing: %s", ...
                    eventsJsonPath);
            end
            cleanup = onCleanup(@() fclose(fileID));
            fprintf(fileID, "%s\n", jsonText);
        end

        function events = buildEventsTable(obj)
            %BUILDEVENTSTABLE Build generic BCI2000 and stimulation events.

            onset = zeros(0,1);
            duration = zeros(0,1);
            trialType = strings(0,1);
            value = strings(0,1);
            sample = zeros(0,1);

            fs = obj.getSamplingFrequency();
            rules = obj.getConfiguredStateRules();

            %% Generic events specified in profile.events
            for ruleIndex = 1:numel(rules)
                rule = rules(ruleIndex);

                if ~isfield(rule, "includeInEvents") || ...
                        ~logical(rule.includeInEvents)
                    continue
                end

                [stateValues, found] = obj.getStateValue(string(rule.path));
                if ~found
                    obj.addValidation("warning", string(rule.path), ...
                        "Configured event state was not found.", ...
                        "buildEventsTable");
                    continue
                end

                stateValues = double(stateValues(:));

                if numel(stateValues) ~= obj.NumberOfSamples
                    error("BCI2000_data:StateLengthMismatch", ...
                        "State '%s' length does not match signal length.", ...
                        string(rule.path));
                end

                runStart = find([true; diff(stateValues) ~= 0]);
                runEnd = [runStart(2:end)-1; numel(stateValues)];

                eventName = string(rule.path);
                if isfield(rule, "name") && strlength(string(rule.name)) > 0
                    eventName = string(rule.name);
                end

                for runIndex = 1:numel(runStart)
                    currentValue = stateValues(runStart(runIndex));
                    if currentValue == 0 || isnan(currentValue)
                        continue
                    end

                    firstSample = runStart(runIndex);
                    lastSample = runEnd(runIndex);

                    onset(end+1,1) = (firstSample - 1) / fs; %#ok<AGROW>
                    duration(end+1,1) = ...
                        (lastSample - firstSample + 1) / fs; %#ok<AGROW>
                    trialType(end+1,1) = eventName; %#ok<AGROW>
                    value(end+1,1) = string(currentValue); %#ok<AGROW>
                    sample(end+1,1) = firstSample - 1; %#ok<AGROW>
                end
            end

            events = table(onset, duration, trialType, value, sample, ...
                VariableNames=["onset","duration","trial_type","value","sample"]);

            %% Add BIDS electrical stimulation events
            stimEvents = obj.buildStimulationEventsTable();

            if height(stimEvents) > 0
                % Add stimulation-specific columns to generic events.
                events.electrical_stimulation_trigger = ...
                    repmat("n/a", height(events), 1);
                events.electrical_stimulation_function_ids = ...
                    repmat("n/a", height(events), 1);

                events = [events; stimEvents];
            end

            if height(events) > 0
                events = sortrows(events, ["onset","trial_type"]);
            end
        end

        function stimEvents = buildStimulationEventsTable(obj)
            %BUILDSTIMULATIONEVENTSTABLE Convert actual stimulation periods
            % into BIDS electrical-stimulation events.
            %
            % eventState defines actual stimulation delivery. triggerState,
            % when supplied, is sampled at/around stimulation onset to retain
            % the triggering condition.
            %
            % triggerTable mode additionally maps trigger values into a
            % StimulationTriggers-style parameter table.
            %
            % parameterSet mode records the trigger state/value directly and
            % leaves function IDs as n/a.

            stimEvents = table( ...
                zeros(0,1), zeros(0,1), strings(0,1), ...
                strings(0,1), zeros(0,1), strings(0,1), strings(0,1), ...
                VariableNames=[ ...
                    "onset","duration","trial_type","value","sample", ...
                    "electrical_stimulation_trigger", ...
                    "electrical_stimulation_function_ids"]);

            config = obj.getStimulationConfig();

            if ~config.enabled
                return
            end

            [stimState, found] = ...
                obj.getStateValue(config.eventState);

            if ~found
                obj.addValidation("warning", config.eventState, ...
                    "Stimulation event state was not found.", ...
                    "buildStimulationEventsTable");
                return
            end

            stimState = double(stimState(:));

            if numel(stimState) ~= obj.NumberOfSamples
                error("BCI2000_data:StateLengthMismatch", ...
                    "Stimulation event state must match signal sample count.");
            end

            %% Trigger state is optional for parameterSet mode
            triggerState = [];
            triggerFound = false;

            if strlength(config.triggerState) > 0
                [triggerState, triggerFound] = ...
                    obj.getStateValue(config.triggerState);

                if triggerFound
                    triggerState = double(triggerState(:));

                    if numel(triggerState) ~= obj.NumberOfSamples
                        error("BCI2000_data:StateLengthMismatch", ...
                            ["Stimulation trigger state must match " ...
                             "signal sample count."]);
                    end
                elseif lower(config.mode) == "triggertable"
                    error("BCI2000_data:MissingStimulationTriggerState", ...
                        ["Configured stimulation trigger state '%s' " ...
                         "was not found."], ...
                        config.triggerState);
                else
                    obj.addValidation("warning", config.triggerState, ...
                        ["Configured stimulation trigger state was not " ...
                         "found; stimulation events will use n/a."], ...
                        "buildStimulationEventsTable");
                end
            end

            %% Trigger table is only required for triggerTable mode
            triggerTable = table();

            if lower(config.mode) == "triggertable"
                triggerTable = obj.getStimulationParameterTable( ...
                    config.triggersPath);

                if height(triggerTable) < max( ...
                        config.triggerRow, config.functionIDsRow)
                    error("BCI2000_data:InvalidStimulationTriggers", ...
                        ["Stimulation trigger table does not contain the " ...
                         "configured trigger/function-ID rows."]);
                end
            end

            fs = obj.getSamplingFrequency();

            runStart = find([true; diff(stimState) ~= 0]);
            runEnd = [runStart(2:end)-1; numel(stimState)];

            onset = zeros(0,1);
            duration = zeros(0,1);
            trialType = strings(0,1);
            eventValue = strings(0,1);
            sample = zeros(0,1);
            triggerDescription = strings(0,1);
            functionIDs = strings(0,1);

            for runIndex = 1:numel(runStart)

                stimValue = stimState(runStart(runIndex));

                if stimValue == 0 || isnan(stimValue)
                    continue
                end

                firstSample = runStart(runIndex);
                lastSample = runEnd(runIndex);

                triggerValue = NaN;

                if triggerFound
                    triggerValue = obj.resolveStimulationTriggerValue( ...
                        triggerState, firstSample, lastSample);
                end

                switch lower(config.mode)

                    case "triggertable"

                        if isnan(triggerValue)
                            triggerText = "n/a";
                            functionText = "n/a";
                        else
                            triggerColumn = round(triggerValue);

                            if triggerColumn < 1 || ...
                                    triggerColumn > width(triggerTable)

                                obj.addValidation("warning", ...
                                    config.triggerState, ...
                                    sprintf(["Trigger value %g does not " ...
                                        "correspond to a stimulation " ...
                                        "trigger-table column."], ...
                                        triggerValue), ...
                                    "buildStimulationEventsTable");

                                triggerText = "n/a";
                                functionText = "n/a";
                            else
                                triggerText = obj.tableEntryToString( ...
                                    triggerTable, ...
                                    config.triggerRow, ...
                                    triggerColumn);

                                functionText = obj.tableEntryToString( ...
                                    triggerTable, ...
                                    config.functionIDsRow, ...
                                    triggerColumn);
                            end
                        end

                    case "parameterset"

                        functionText = "n/a";

                        if strlength(config.triggerState) == 0
                            triggerText = "n/a";
                        elseif isnan(triggerValue)
                            triggerText = config.triggerState;
                        else
                            triggerText = ...
                                config.triggerState + "=" + ...
                                string(triggerValue);
                        end
                end

                onset(end+1,1) = ...
                    (firstSample - 1) / fs; %#ok<AGROW>

                duration(end+1,1) = ...
                    (lastSample - firstSample + 1) / fs; %#ok<AGROW>

                trialType(end+1,1) = ...
                    "electrical_stimulation"; %#ok<AGROW>

                eventValue(end+1,1) = ...
                    string(stimValue); %#ok<AGROW>

                sample(end+1,1) = ...
                    firstSample - 1; %#ok<AGROW>

                triggerDescription(end+1,1) = ...
                    triggerText; %#ok<AGROW>

                functionIDs(end+1,1) = ...
                    functionText; %#ok<AGROW>
            end

            stimEvents = table( ...
                onset, duration, trialType, eventValue, sample, ...
                triggerDescription, functionIDs, ...
                VariableNames=[ ...
                    "onset","duration","trial_type","value","sample", ...
                    "electrical_stimulation_trigger", ...
                    "electrical_stimulation_function_ids"]);
        end

        function config = getStimulationConfig(obj)
            %GETSTIMULATIONCONFIG Normalize stimulation settings from the
            % primary profile or an active extension profile.
            %
            % Supported modes:
            %
            %   triggerTable
            %       CorTec-style configuration using a parameter table in
            %       which the trigger-state value selects a configuration
            %       column.
            %
            %   parameterSet
            %       Generic stimulator configuration where stimulation
            %       intervals are defined by eventState and the configured
            %       stimulation parameters are exported as a parameter set.

            config = struct( ...
                "enabled", false, ...
                "mode", "triggerTable", ...
                "sourceProfile", "", ...
                "eventState", "", ...
                "triggerState", "", ...
                "parametersPath", "", ...
                "triggersPath", "", ...
                "triggerRow", 1, ...
                "functionIDsRow", 2, ...
                "parameterPaths", strings(0,1));

            stimulation = [];
            sourceProfile = "";

            %% Prefer stimulation declared by the main profile
            if isfield(obj.Profile, "stimulation") && ...
                    ~isempty(obj.Profile.stimulation)
                stimulation = obj.Profile.stimulation;

                if isfield(obj.Profile, "profileName")
                    sourceProfile = string(obj.Profile.profileName);
                else
                    sourceProfile = "primary";
                end
            end

            %% Otherwise inspect active extension profiles
            if isempty(stimulation)
                for profileIndex = 1:numel(obj.ExtensionProfiles)
                    extensionProfile = obj.ExtensionProfiles{profileIndex};

                    if isfield(extensionProfile, "stimulation") && ...
                            ~isempty(extensionProfile.stimulation)

                        candidate = extensionProfile.stimulation;

                        if isfield(candidate, "enabled") && ...
                                logical(candidate.enabled)
                            stimulation = candidate;

                            if isfield(extensionProfile, "profileName")
                                sourceProfile = ...
                                    string(extensionProfile.profileName);
                            else
                                sourceProfile = ...
                                    "extension" + string(profileIndex);
                            end
                            break
                        end
                    end
                end
            end

            if isempty(stimulation)
                return
            end

            S = stimulation;

            if isfield(S, "enabled")
                config.enabled = logical(S.enabled);
            end

            if ~config.enabled
                return
            end

            config.sourceProfile = sourceProfile;

            if isfield(S, "mode") && strlength(string(S.mode)) > 0
                config.mode = string(S.mode);
            end

            if ~isfield(S, "eventState") || ...
                    strlength(string(S.eventState)) == 0
                error("BCI2000_data:InvalidStimulationProfile", ...
                    "Enabled stimulation profile requires 'eventState'.");
            end

            config.eventState = string(S.eventState);

            if isfield(S, "triggerState")
                config.triggerState = string(S.triggerState);
            end

            switch lower(config.mode)

                case "triggertable"

                    required = ["triggerState", ...
                        "parametersPath", "triggersPath"];

                    for idx = 1:numel(required)
                        if ~isfield(S, required(idx)) || ...
                                strlength(string(S.(required(idx)))) == 0
                            error("BCI2000_data:InvalidStimulationProfile", ...
                                ["Stimulation mode 'triggerTable' " ...
                                 "requires '%s'."], required(idx));
                        end
                    end

                    config.triggerState = string(S.triggerState);
                    config.parametersPath = ...
                        string(S.parametersPath);
                    config.triggersPath = ...
                        string(S.triggersPath);

                    if isfield(S, "triggerRow")
                        config.triggerRow = double(S.triggerRow);
                    end

                    if isfield(S, "functionIDsRow")
                        config.functionIDsRow = ...
                            double(S.functionIDsRow);
                    end

                case "parameterset"

                    if ~isfield(S, "parameterPaths") || ...
                            isempty(S.parameterPaths)
                        error("BCI2000_data:InvalidStimulationProfile", ...
                            ["Stimulation mode 'parameterSet' requires " ...
                             "'parameterPaths'."]);
                    end

                    config.parameterPaths = ...
                        string(S.parameterPaths(:));

                otherwise

                    error("BCI2000_data:UnknownStimulationMode", ...
                        "Unknown stimulation mode '%s'.", ...
                        config.mode);
            end
        end

        function value = resolveStimulationTriggerValue(~, ...
                triggerState, firstSample, lastSample)
            %RESOLVESTIMULATIONTRIGGERVALUE Select the trigger-state value
            % corresponding to one stimulation interval.
            %
            % Prefer a non-zero value during the stimulation interval.
            % If none exists, use the most recent non-zero state value
            % preceding the stimulation onset.

            intervalValues = triggerState(firstSample:lastSample);
            idx = find(intervalValues ~= 0 & ...
                ~isnan(intervalValues), 1, "first");

            if ~isempty(idx)
                value = intervalValues(idx);
                return
            end

            previous = triggerState(1:firstSample);
            idx = find(previous ~= 0 & ~isnan(previous), 1, "last");

            if isempty(idx)
                value = NaN;
            else
                value = previous(idx);
            end
        end

        function T = getStimulationParameterTable(obj, parameterPath)
            %GETSTIMULATIONPARAMETERTABLE Parse a BCI2000 matrix parameter.
            %
            % Scalar NumericValue parameters are handled separately by
            % getStimulationParameterValue(). Matrix/mixed values use the
            % supplied parseBCI2000_parameters_values() helper.

            fieldName = obj.normalizeParameterFieldPath(parameterPath);

            if exist("parseBCI2000_parameters_values", "file") ~= 2
                error("BCI2000_data:MissingParameterParser", ...
                    ["parseBCI2000_parameters_values.m must be available " ...
                     "on the MATLAB path."]);
            end

            try
                T = parseBCI2000_parameters_values( ...
                    obj.Parameters, fieldName);
            catch ME
                throwAsCaller(addCause( ...
                    MException( ...
                    "BCI2000_data:StimulationParameterParseFailed", ...
                    "Could not parse stimulation parameter '%s'.", ...
                    fieldName), ME));
            end
        end

        function value = getStimulationParameterValue(obj, parameterPath)
            %GETSTIMULATIONPARAMETERVALUE Return scalar NumericValue when
            % possible; otherwise return a parsed MATLAB table.

            normalizedPath = obj.normalizeParameterFieldPath(parameterPath);

            [numericValue, found] = ...
                obj.getParameterNumericValue(normalizedPath);

            if found && isnumeric(numericValue) && ...
                    isscalar(numericValue) && isfinite(numericValue)
                value = double(numericValue);
                return
            end

            value = obj.getStimulationParameterTable(normalizedPath);
        end

        function fieldName = normalizeParameterFieldPath(~, parameterPath)
            %NORMALIZEPARAMETERFIELDPATH Convert profile path such as
            % "parameters.StimulationTriggers" to "StimulationTriggers".

            parts = split(string(parameterPath), ".");
            if numel(parts) > 1 && strcmpi(parts(1), "parameters")
                parts = parts(2:end);
            end

            if numel(parts) ~= 1
                error("BCI2000_data:UnsupportedParameterPath", ...
                    ["The current BCI2000 parameter parser supports " ...
                     "top-level parameter fields only: %s"], ...
                    parameterPath);
            end

            fieldName = parts(1);
        end

        function value = tableEntryToString(~, T, row, col)
            %TABLEENTRYTOSTRING Serialize one parsed parameter-table entry.

            value = T{row,col};

            if iscell(value) && numel(value) == 1
                value = value{1};
            end

            if isnumeric(value)
                if isscalar(value)
                    value = string(value);
                else
                    value = string(mat2str(value));
                end
            elseif isstring(value) || ischar(value)
                value = string(value);
            elseif iscell(value)
                value = string(strjoin(string(value), ","));
            else
                value = string(value);
            end
        end

        function metadata = buildEventsSidecar(obj)
            %BUILDEVENTSSIDECAR Describe BIDS event columns.

            metadata = struct();

            metadata.onset = struct( ...
                "LongName", "Event onset", ...
                "Description", ...
                    "Event onset relative to recording start.", ...
                "Units", "s");

            metadata.duration = struct( ...
                "LongName", "Event duration", ...
                "Description", "Event duration.", ...
                "Units", "s");

            metadata.trial_type = struct( ...
                "LongName", "Event type", ...
                "Description", ...
                    ["BCI2000-derived event type. Electrical stimulation " ...
                     "events use trial_type 'electrical_stimulation'."]);

            metadata.value = struct( ...
                "LongName", "Source state value", ...
                "Description", ...
                    "BCI2000 state value associated with the event.");

            metadata.sample = struct( ...
                "LongName", "Event onset sample", ...
                "Description", ...
                    "Zero-based sample index corresponding to event onset.");

            metadata.electrical_stimulation_trigger = struct( ...
                "LongName", "Electrical stimulation trigger", ...
                "Description", ...
                    ["Trigger expression/configuration extracted from the " ...
                     "configured trigger row of the BCI2000 " ...
                     "StimulationTriggers parameter."]);

            metadata.electrical_stimulation_function_ids = struct( ...
                "LongName", "Electrical stimulation function IDs", ...
                "Description", ...
                    ["Stimulation function ID or IDs extracted from the " ...
                     "configured function-ID row of the BCI2000 " ...
                     "StimulationTriggers parameter."]);
        end

        function stimParametersPath = writeStimulationParameters( ...
                obj, outputFolder, baseName, overwrite)
            %WRITESTIMULATIONPARAMETERS Write custom stimulation metadata.
            %
            % Output:
            % <BIDS root>/stimuli/
            %   sub-..._task-...[_acq-...][_run-...]_stimParameters.json

            stimParametersPath = "";
            config = obj.getStimulationConfig();

            if ~config.enabled
                return
            end

            payload = struct();

            payload.Description = ...
                ["Custom BCI2000 stimulation configuration metadata. " ...
                 "This file is additional to the BIDS specification."];

            payload.SourceProfile = config.sourceProfile;
            payload.Mode = config.mode;
            payload.EventState = config.eventState;

            if strlength(config.triggerState) > 0
                payload.TriggerState = config.triggerState;
            end

            switch lower(config.mode)

                case "triggertable"

                    parametersValue = ...
                        obj.getStimulationParameterValue( ...
                            config.parametersPath);

                    triggersValue = ...
                        obj.getStimulationParameterValue( ...
                            config.triggersPath);

                    payload.StimulationParameters = ...
                        obj.makeJSONFriendlyParameter( ...
                            parametersValue);

                    payload.StimulationTriggers = ...
                        obj.makeJSONFriendlyParameter( ...
                            triggersValue);

                case "parameterset"

                    parameterPayload = struct();

                    for parameterIndex = 1:numel(config.parameterPaths)

                        parameterPath = ...
                            config.parameterPaths(parameterIndex);

                        try
                            parameterValue = ...
                                obj.getStimulationParameterValue( ...
                                    parameterPath);

                            fieldName = matlab.lang.makeValidName( ...
                                obj.normalizeParameterFieldPath( ...
                                    parameterPath));

                            parameterPayload.(fieldName) = ...
                                obj.makeJSONFriendlyParameter( ...
                                    parameterValue);

                        catch ME
                            obj.addValidation("warning", ...
                                parameterPath, ...
                                "Could not export stimulation parameter: " + ...
                                string(ME.message), ...
                                "writeStimulationParameters");
                        end
                    end

                    payload.Parameters = parameterPayload;
            end

            datasetRoot = obj.getBIDSDatasetRoot(outputFolder);
            stimuliFolder = fullfile(datasetRoot, "stimuli");

            if ~isfolder(stimuliFolder)
                [created, message] = mkdir(stimuliFolder);

                if ~created
                    error("BCI2000_data:StimuliDirectoryCreationFailed", ...
                        "Could not create stimuli directory '%s': %s", ...
                        stimuliFolder, message);
                end
            end

            entityBase = regexprep(string(baseName), ...
                "_(ieeg|eeg|meg)$", "", "ignorecase");

            stimParametersPath = fullfile(stimuliFolder, ...
                entityBase + "_stimParameters.json");

            if isfile(stimParametersPath) && ~overwrite
                error("BCI2000_data:StimParametersExists", ...
                    ["Stimulation parameter file already exists: %s. " ...
                     "Set Overwrite=true to replace it."], ...
                    stimParametersPath);
            end

            jsonText = jsonencode(payload, PrettyPrint=true);

            fileID = fopen(stimParametersPath, "w");

            if fileID == -1
                error("BCI2000_data:StimParametersWriteFailed", ...
                    "Could not open stimulation parameter JSON: %s", ...
                    stimParametersPath);
            end

            cleanup = onCleanup(@() fclose(fileID));
            fprintf(fileID, "%s\n", jsonText);
        end

        function output = makeJSONFriendlyParameter(~, value)
            %MAKEJSONFRIENDLYPARAMETER Convert scalar/table to JSON object.

            if istable(value)
                output = struct();
                output.Columns = string(value.Properties.VariableNames);

                if ~isempty(value.Properties.RowNames)
                    output.RowLabels = string(value.Properties.RowNames);
                end

                if height(value) == 0
                    output.Rows = struct([]);
                else
                    output.Rows = table2struct(value);
                end
            else
                output = value;
            end
        end

        function datasetRoot = getBIDSDatasetRoot(~, outputFolder)
            %GETBIDSDATASETROOT Infer dataset root from a BIDS iEEG folder.
            %
            % For:
            %   <root>/sub-01/ses-01/ieeg
            % returns:
            %   <root>
            %
            % For non-standard output paths, falls back to outputFolder.

            outputFolder = string(outputFolder);
            normalized = strrep(outputFolder, "\", "/");
            parts = split(normalized, "/");

            subjectIndex = find(startsWith(parts, "sub-"), 1, "last");

            if isempty(subjectIndex)
                datasetRoot = outputFolder;
                return
            end

            rootParts = parts(1:subjectIndex-1);

            if isempty(rootParts)
                datasetRoot = filesep;
            else
                datasetRoot = strjoin(rootParts, "/");

                % Preserve leading slash on Unix/macOS.
                if startsWith(normalized, "/") && ...
                        ~startsWith(datasetRoot, "/")
                    datasetRoot = "/" + datasetRoot;
                end
            end
        end

        function rules = getConfiguredStateRules(obj)
            %GETCONFIGUREDSTATERULES Return configured state rules.
            %
            % Special generic syntax:
            %   "events": "all"
            %
            % expands every available BCI2000 state into an auxiliary
            % signal rule. These automatically generated rules are never
            % included in events.tsv.

            rules = struct([]);

            %% Primary profile rules
            if ~isempty(fieldnames(obj.Profile)) && ...
                    isfield(obj.Profile, "events") && ...
                    ~isempty(obj.Profile.events)

                profileEvents = obj.Profile.events;

                if (ischar(profileEvents) || isstring(profileEvents)) && ...
                        isscalar(string(profileEvents)) && ...
                        strcmpi(string(profileEvents), "all")

                    stateNames = string(fieldnames(obj.States));

                    generatedRules = repmat(struct( ...
                        "name", "", ...
                        "source", "state", ...
                        "path", "", ...
                        "includeAsAuxiliarySignal", true, ...
                        "includeInEvents", false, ...
                        "units", "n/a"), ...
                        numel(stateNames), 1);

                    for stateIndex = 1:numel(stateNames)
                        generatedRules(stateIndex).name = stateNames(stateIndex);
                        generatedRules(stateIndex).path = stateNames(stateIndex);
                    end

                    rules = generatedRules;

                else
                    primaryRules = profileEvents;

                    if iscell(primaryRules)
                        primaryRules = [primaryRules{:}];
                    end

                    if ~isstruct(primaryRules)
                        error("BCI2000_data:InvalidStateRules", ...
                            ["Profile events must be an array of objects " ...
                             "or the string 'all'."]);
                    end

                    rules = primaryRules;
                end
            end

            %% Active extension-profile rules
            for profileIndex = 1:numel(obj.ExtensionProfiles)
                extensionProfile = obj.ExtensionProfiles{profileIndex};

                if ~isfield(extensionProfile, "states") || ...
                        isempty(extensionProfile.states)
                    continue
                end

                extensionRules = extensionProfile.states;

                if iscell(extensionRules)
                    extensionRules = [extensionRules{:}];
                end

                if ~isstruct(extensionRules)
                    error("BCI2000_data:InvalidStateRules", ...
                        "Extension profile states must be an array of objects.");
                end

                if isempty(rules)
                    rules = extensionRules;
                else
                    [rules, extensionRules] = ...
                        obj.harmonizeStructFields(rules, extensionRules);

                    rules = [rules(:); extensionRules(:)]; %#ok<AGROW>
                end
            end
        end


        function [a, b] = harmonizeStructFields(~, a, b)
            %HARMONIZESTRUCTFIELDS Add missing fields before concatenating
            % rules originating from different JSON profiles.

            fieldsA = string(fieldnames(a));
            fieldsB = string(fieldnames(b));
            allFields = unique([fieldsA; fieldsB]);

            for fieldIndex = 1:numel(allFields)
                fieldName = allFields(fieldIndex);

                if ~isfield(a, fieldName)
                    [a.(fieldName)] = deal([]);
                end

                if ~isfield(b, fieldName)
                    [b.(fieldName)] = deal([]);
                end
            end

            % MATLAB requires identical field ordering for concatenation.
            a = orderfields(a, cellstr(allFields));
            b = orderfields(b, cellstr(allFields));
        end

        function [value, found] = getStateValue(obj, statePath)
            pathParts = split(string(statePath), ".");
            currentValue = obj.States;
            found = true;

            for pathIndex = 1:numel(pathParts)
                if ~isstruct(currentValue)
                    found = false;
                    value = [];
                    return
                end

                actualFields = string(fieldnames(currentValue));
                matchIndex = find(strcmpi(actualFields, pathParts(pathIndex)), 1);

                if isempty(matchIndex)
                    found = false;
                    value = [];
                    return
                end

                currentValue = currentValue.(actualFields(matchIndex));
            end

            value = currentValue;
        end

        function fs = getSamplingFrequency(obj)
            if ~isfield(obj.Metadata, "Recording") || ...
                    ~isfield(obj.Metadata.Recording, "SamplingFrequency")
                error("BCI2000_data:MissingSamplingFrequency", ...
                    ["SamplingFrequency is not available in canonical " ...
                     "metadata. Apply a conversion profile before export."]);
            end

            fs = double(obj.Metadata.Recording.SamplingFrequency);
            if ~isscalar(fs) || ~isfinite(fs) || fs <= 0
                error("BCI2000_data:InvalidSamplingFrequency", ...
                    "SamplingFrequency must be a positive scalar.");
            end
        end

        function channelNames = getExportChannelNames(obj)
            nChannels = obj.NumberOfChannels;

            if height(obj.Channels) == nChannels && ...
                    ismember("name", string(obj.Channels.Properties.VariableNames))
                channelNames = string(obj.Channels.name(:));
            else
                channelNames = "Ch" + string((1:nChannels).');
            end

            if any(ismissing(channelNames) | strlength(channelNames) == 0)
                error("BCI2000_data:InvalidChannelNames", ...
                    "All exported channels must have non-empty names.");
            end

            if numel(unique(channelNames)) ~= nChannels
                error("BCI2000_data:DuplicateChannelNames", ...
                    "Channel names must be unique for MEF export.");
            end
        end

        function units = getExportUnits(obj)
            %GETEXPORTUNITS Return one physical-unit label per neural channel.
            %
            % Auxiliary state units are appended separately by
            % getAuxiliaryStateSignals().

            nChannels = obj.NumberOfChannels;
            units = repmat("uV", nChannels, 1);

            if height(obj.Channels) == nChannels && ...
                    ismember("units", string(obj.Channels.Properties.VariableNames))
                channelUnits = string(obj.Channels.units(:));

                valid = ~ismissing(channelUnits) & strlength(channelUnits) > 0;
                units(valid) = channelUnits(valid);
                units(~valid) = "n/a";
            end
        end

        function recordingTime = getRecordingStartTime(obj)
            %GETRECORDINGSTARTTIME Return the canonical recording start time.
            %
            % Prefer Metadata.Recording.StartTime produced by the conversion
            % profile. Fall back to BCI2000 StorageTime when necessary.

            recordingTime = NaT;

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "StartTime")
                sourceTime = obj.Metadata.Recording.StartTime;

                if isdatetime(sourceTime)
                    recordingTime = sourceTime;
                else
                    try
                        recordingTime = datetime(sourceTime);
                    catch
                        error("BCI2000_data:InvalidStartTime", ...
                            "Metadata.Recording.StartTime could not be parsed.");
                    end
                end
            elseif exist("read_bcidate", "file") == 2
                try
                    recordingDateNumber = read_bcidate(obj.Parameters);
                    recordingTime = datetime(recordingDateNumber, ...
                        "ConvertFrom", "datenum");
                catch ME
                    throwAsCaller(addCause( ...
                        MException("BCI2000_data:StorageTimeReadFailed", ...
                        "Could not read the BCI2000 StorageTime parameter."), ME));
                end
            else
                [storageTime, found] = obj.getParameterValue("StorageTime");
                if found
                    if iscell(storageTime)
                        storageTime = storageTime{1};
                    end
                    try
                        recordingTime = datetime(string(storageTime));
                    catch
                        error("BCI2000_data:StorageTimeReadFailed", ...
                            ["StorageTime is present but could not be parsed, " ...
                             "and read_bcidate is not available."]);
                    end
                end
            end

            if isnat(recordingTime)
                error("BCI2000_data:MissingStartTime", ...
                    ["A recording start time is required for signal export. " ...
                     "Map Recording.StartTime in the profile or make " ...
                     "BCI2000 read_bcidate available on the MATLAB path."]);
            end
        end

        function startUutc = getRecordingStartUutc(obj)
            %GETRECORDINGSTARTUUTC Return MEF start time in microseconds UTC.

            recordingTime = obj.getRecordingStartTime();

            if isempty(recordingTime.TimeZone)
                recordingTime.TimeZone = "local";
            end

            startUutc = int64(round(posixtime(recordingTime) * 1e6));
        end

        function [value, found] = getParameterNumericValue(obj, parameterPath)
            %GETPARAMETERNUMERICVALUE Resolve a BCI2000 numeric parameter.
            % Prefer NumericValue returned by load_bcidat. Fall back to
            % parsing the Value field when required.

            pathParts = split(string(parameterPath), ".");
            currentValue = obj.Parameters;
            found = true;

            for pathIndex = 1:numel(pathParts)
                requestedName = pathParts(pathIndex);

                if ~isstruct(currentValue)
                    found = false;
                    value = [];
                    return
                end

                actualFields = string(fieldnames(currentValue));
                matchIndex = find(strcmpi(actualFields, requestedName), 1);

                if isempty(matchIndex)
                    found = false;
                    value = [];
                    return
                end

                currentValue = currentValue.(actualFields(matchIndex));
            end

            if isstruct(currentValue) && isfield(currentValue, "NumericValue")
                value = currentValue.NumericValue;
                if ~isempty(value) && ~all(isnan(value(:)))
                    return
                end
            end

            if isstruct(currentValue) && isfield(currentValue, "Value")
                currentValue = currentValue.Value;
            end

            if isnumeric(currentValue)
                value = double(currentValue);
                return
            end

            if iscell(currentValue)
                value = nan(size(currentValue));
                for valueIndex = 1:numel(currentValue)
                    value(valueIndex) = str2double(string(currentValue{valueIndex}));
                end
            else
                value = str2double(string(currentValue));
            end

            if isempty(value) || any(isnan(value(:)))
                found = false;
                value = [];
            end
        end

        function initializeDataStructure(obj)
            obj.Metadata = struct( ...
                "Subject", struct(), ...
                "Session", struct(), ...
                "Task", struct(), ...
                "Recording", struct(), ...
                "Device", struct(), ...
                "Provenance", struct());

            obj.Channels = table( ...
                Size=[0 7], ...
                VariableTypes=[ ...
                    "string", "string", "string", "double", ...
                    "string", "string", "string"], ...
                VariableNames=[ ...
                    "name", "type", "units", "sampling_frequency", ...
                    "reference", "status", "status_description"]);

            obj.Events = table( ...
                Size=[0 6], ...
                VariableTypes=[ ...
                    "double", "double", "string", "string", ...
                    "double", "string"], ...
                VariableNames=[ ...
                    "onset", "duration", "trial_type", "value", ...
                    "sample", "source_state"]);

            obj.Validation = table( ...
                Size=[0 5], ...
                VariableTypes=[ ...
                    "datetime", "categorical", "string", "string", "string"], ...
                VariableNames=[ ...
                    "time", "severity", "field", "message", "stage"]);
        end

        function validateProfileStructure(~, profile)
            requiredFields = ["profileName", "profileVersion", "metadata"];

            for fieldName = requiredFields
                if ~isfield(profile, fieldName)
                    error("BCI2000_data:InvalidProfile", ...
                        "Profile is missing required field '%s'.", fieldName);
                end
            end
        end

        function [value, found] = evaluateMappingNode(obj, node, targetPath)
            %EVALUATEMAPPINGNODE Recursively evaluate profile metadata.
            % A structure containing a "source" field is a leaf mapping
            % rule. Otherwise its fields are interpreted as nested metadata.

            value = [];
            found = false;

            if ~isstruct(node)
                error("BCI2000_data:InvalidMappingNode", ...
                    "Profile mapping node '%s' must be an object.", targetPath);
            end

            if isfield(node, "source")
                [value, found, sourceDescription] = ...
                    obj.evaluateMappingRule(node);

                if found
                    obj.addValidation("info", targetPath, ...
                        "Mapped from " + sourceDescription + ".", ...
                        "applyProfile");
                else
                    isRequired = isfield(node, "required") && ...
                        logical(node.required);

                    if isRequired
                        obj.addValidation("error", targetPath, ...
                            "Required profile mapping could not be resolved.", ...
                            "applyProfile");
                    else
                        obj.addValidation("warning", targetPath, ...
                            "Optional profile mapping could not be resolved.", ...
                            "applyProfile");
                    end
                end
                return
            end

            childNames = fieldnames(node);
            nested = struct();
            anyFound = false;

            for childIndex = 1:numel(childNames)
                childName = childNames{childIndex};
                [childValue, childFound] = obj.evaluateMappingNode( ...
                    node.(childName), targetPath + "." + childName);

                if childFound
                    nested.(childName) = childValue;
                    anyFound = true;
                end
            end

            if anyFound
                value = nested;
                found = true;
            end
        end

        function [value, found, sourceDescription] = ...
                evaluateMappingRule(obj, rule)

            value = [];
            found = false;
            sourceDescription = "";

            if ~isfield(rule, "source")
                error("BCI2000_data:InvalidMappingRule", ...
                    "Each mapping rule must define a source.");
            end

            sourceType = string(rule.source);

            switch lower(sourceType)
                case "constant"
                    if ~isfield(rule, "value")
                        error("BCI2000_data:InvalidMappingRule", ...
                            "A constant mapping must define a value.");
                    end

                    value = rule.value;
                    found = true;
                    sourceDescription = "profile constant";

                case "parameter"
                    candidateNames = strings(0,1);

                    if isfield(rule, "path")
                        candidateNames(end+1,1) = string(rule.path);
                    end

                    if isfield(rule, "aliases")
                        candidateNames = [candidateNames; string(rule.aliases(:))];
                    end

                    for candidateIndex = 1:numel(candidateNames)
                        candidateName = candidateNames(candidateIndex);
                        [candidateValue, candidateFound] = ...
                            obj.getParameterValue(candidateName);

                        if candidateFound
                            value = candidateValue;

                            % Optional selector for matrix/cell parameters.
                            % Example JSON: "valueIndex": [2, 1]
                            if isfield(rule, "valueIndex")
                                index = double(rule.valueIndex(:).');
                                if numel(index) ~= 2
                                    error("BCI2000_data:InvalidValueIndex", ...
                                        "valueIndex must contain [row, column].");
                                end
                                try
                                    if iscell(value)
                                        value = value{index(1), index(2)};
                                    else
                                        value = value(index(1), index(2));
                                    end
                                catch ME
                                    throwAsCaller(addCause( ...
                                        MException("BCI2000_data:ValueIndexFailed", ...
                                        "Could not index parameter '%s' at [%d,%d].", ...
                                        candidateName, index(1), index(2)), ME));
                                end
                            end

                            found = true;
                            sourceDescription = ...
                                "BCI2000 parameter '" + candidateName + "'";
                            break
                        end
                    end

                otherwise
                    error("BCI2000_data:UnsupportedSource", ...
                        "Unsupported mapping source: %s", sourceType);
            end

            if ~found && isfield(rule, "default")
                value = rule.default;
                found = true;
                sourceDescription = "profile default";
            end

            if found && isfield(rule, "transform")
                value = obj.applyTransform( ...
                    string(rule.transform), value);
            end
        end

        function [value, found] = getParameterValue(obj, parameterPath)
            %GETPARAMETERVALUE Resolve a parameter by direct or nested path.
            %
            % Supported examples:
            %   "SamplingRate"
            %   "Source.SamplingRate"
            %
            % BCI2000 parameter structures may contain an additional Value
            % field, which is unwrapped automatically.

            pathParts = split(string(parameterPath), ".");
            currentValue = obj.Parameters;
            found = true;

            for pathIndex = 1:numel(pathParts)
                requestedName = pathParts(pathIndex);

                if ~isstruct(currentValue)
                    found = false;
                    value = [];
                    return
                end

                actualFields = string(fieldnames(currentValue));
                matchIndex = find(strcmpi(actualFields, requestedName), 1);

                if isempty(matchIndex)
                    found = false;
                    value = [];
                    return
                end

                currentValue = currentValue.(actualFields(matchIndex));
            end

            if isstruct(currentValue) && isfield(currentValue, "Value")
                currentValue = currentValue.Value;
            end

            value = currentValue;
        end

        function value = applyTransform(~, transformName, value)
            switch lower(transformName)
                case "identity"
                    return

                case "todouble"
                    value = double(value);

                case "tostring"
                    value = string(value);

                case "parsenumeric"
                    value = BCI2000_data.parseNumericValue(value);

                case "datetime"
                    value = BCI2000_data.parseDateTimeValue(value);

                case "extractunitsfromgain"
                    value = BCI2000_data.extractUnitsFromGain(value);

                case "joinstrings"
                    stringsToJoin = string(value(:));
                    stringsToJoin = stringsToJoin(~ismissing(stringsToJoin) & ...
                        strlength(strtrim(stringsToJoin)) > 0);
                    if isempty(stringsToJoin)
                        value = "n/a";
                    else
                        value = strjoin(stringsToJoin, ", ");
                    end

                otherwise
                    error("BCI2000_data:UnknownTransform", ...
                        "Unknown profile transform: %s", transformName);
            end
        end

        function buildChannelTable(obj)
            nChannels = obj.NumberOfChannels;
            if nChannels == 0
                return
            end

            names = "Ch" + string((1:nChannels).');
            channelType = repmat("ECOG", nChannels, 1);
            units = repmat("uV", nChannels, 1);
            samplingFrequency = nan(nChannels, 1);
            reference = repmat("n/a", nChannels, 1);
            status = repmat("good", nChannels, 1);
            statusDescription = repmat("", nChannels, 1);

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "SamplingFrequency")
                samplingFrequency(:) = ...
                    double(obj.Metadata.Recording.SamplingFrequency);
            end

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "ChannelNames")
                profileNames = string(obj.Metadata.Recording.ChannelNames(:));
                if numel(profileNames) == nChannels
                    names = profileNames;
                else
                    obj.addValidation("warning", "Channels.name", ...
                        "Mapped channel-name count does not match signal channels.", ...
                        "buildChannelTable");
                end
            end

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "ChannelType")
                channelType(:) = string(obj.Metadata.Recording.ChannelType);
            end

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "ChannelUnits")
                units(:) = string(obj.Metadata.Recording.ChannelUnits);
            end

            if isfield(obj.Metadata, "Recording") && ...
                    isfield(obj.Metadata.Recording, "Reference")
                reference(:) = string(obj.Metadata.Recording.Reference);
            end

            obj.Channels = table( ...
                names, channelType, units, samplingFrequency, ...
                reference, status, statusDescription, ...
                VariableNames=[ ...
                    "name", "type", "units", "sampling_frequency", ...
                    "reference", "status", "status_description"]);
        end

        function addValidation(obj, severity, field, message, stage)
            newRow = table( ...
                datetime("now"), ...
                categorical(string(severity), ...
                    ["info", "warning", "error"]), ...
                string(field), string(message), string(stage), ...
                VariableNames=obj.Validation.Properties.VariableNames);

            obj.Validation = [obj.Validation; newRow];
        end

        function assertRecordingLoaded(obj)
            if isempty(obj.Signal)
                error("BCI2000_data:NoRecording", ...
                    "Load a BCI2000 recording before applying a profile.");
            end
        end

        function assertProfileLoaded(obj)
            if isempty(fieldnames(obj.Profile))
                error("BCI2000_data:NoProfile", ...
                    "Load a conversion profile before applying it.");
            end
        end
    end

    methods (Static, Access = private)
        function value = parseNumericValue(value)
            %PARSENUMERICVALUE Convert common BCI2000 numeric representations.

            if iscell(value)
                if numel(value) ~= 1
                    error("BCI2000_data:NumericParseFailed", ...
                        "Expected a scalar numeric parameter value.");
                end
                value = value{1};
            end

            if isnumeric(value)
                value = double(value);
                return
            end

            valueString = strtrim(string(value));
            if numel(valueString) ~= 1
                error("BCI2000_data:NumericParseFailed", ...
                    "Expected a scalar numeric parameter value.");
            end

            numericValue = str2double(valueString);

            if isnan(numericValue)
                % Accept values such as "1000Hz" or "1kHz".
                token = regexp(valueString, ...
                    "^([-+]?\d*\.?\d+)\s*(k?Hz)?$", ...
                    "tokens", "once", "ignorecase");

                if isempty(token)
                    error("BCI2000_data:NumericParseFailed", ...
                        "Could not parse numeric value '%s'.", valueString);
                end

                numericValue = str2double(token{1});

                if numel(token) >= 2 && strcmpi(token{2}, "kHz")
                    numericValue = numericValue * 1000;
                end
            end

            value = numericValue;
        end

        function units = extractUnitsFromGain(value)
            %EXTRACTUNITSFROMGAIN Extract physical unit suffixes from
            % BCI2000 SourceChGain values such as "0.1muV".

            if iscell(value)
                raw = string(value(:));
            end

            units = strings(size(raw));
            for idx = 1:numel(raw)
                token = regexp(strtrim(raw(idx)), ...
                    '[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?\s*(.*)$', ...
                    'tokens', 'once');

                if isempty(token) || strlength(strtrim(string(token{1}))) == 0
                    units(idx) = "n/a";
                else
                    unit = strtrim(string(token{1}));
                    unit = replace(unit, ["µV", "μV", "muV"], "uV");
                    units(idx) = unit;
                end
            end

            uniqueUnits = unique(units);
            if numel(uniqueUnits) == 1
                units = uniqueUnits;
            end
        end

        function value = parseDateTimeValue(value)
            %PARSEDATETIMEVALUE Convert a BCI2000 date/time parameter to
            % a MATLAB datetime scalar.
            %
            % The function accepts datetime values directly and unwraps
            % scalar cells/strings. It first lets MATLAB infer the input
            % format, then tries common BCI2000 StorageTime representations.
            %
            % No timezone is assigned here because BCI2000 StorageTime may
            % not encode one. getRecordingStartUutc() assigns the local
            % timezone when an unzoned datetime is exported to MEF.

            if isdatetime(value)
                if ~isscalar(value)
                    error("BCI2000_data:DateTimeParseFailed", ...
                        "Datetime profile values must be scalar.");
                end
                return
            end

            if iscell(value)
                if numel(value) ~= 1
                    error("BCI2000_data:DateTimeParseFailed", ...
                        "Datetime profile values must contain one timestamp.");
                end
                value = value{1};
            end

            valueString = strtrim(string(value));

            if numel(valueString) ~= 1 || ismissing(valueString) || ...
                    strlength(valueString) == 0
                error("BCI2000_data:DateTimeParseFailed", ...
                    "Could not parse an empty or non-scalar datetime value.");
            end

            % First use MATLAB's automatic datetime parser.
            try
                value = datetime(valueString);
                if ~isnat(value)
                    return
                end
            catch
                % Continue with explicit formats below.
            end

            % Common date/time layouts encountered in BCI2000 parameters.
            inputFormats = [ ...
                "yyyy-MM-dd'T'HH:mm:ss.SSS", ...
                "yyyy-MM-dd'T'HH:mm:ss", ...
                "yyyy-MM-dd HH:mm:ss.SSS", ...
                "yyyy-MM-dd HH:mm:ss", ...
                "yyyyMMddHHmmss", ...
                "yyyyMMdd'T'HHmmss", ...
                "yyyy-MM-dd"];

            for formatIndex = 1:numel(inputFormats)
                try
                    candidate = datetime(valueString, ...
                        "InputFormat", inputFormats(formatIndex));
                    if ~isnat(candidate)
                        value = candidate;
                        return
                    end
                catch
                    % Try the next supported representation.
                end
            end

            error("BCI2000_data:DateTimeParseFailed", ...
                "Could not convert '%s' to a MATLAB datetime.", valueString);
        end
    end
end
