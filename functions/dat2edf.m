function outputPath = dat2edf(signal, outputPath, channelNames, ...
        samplingFrequency, recordingStartTime, options)
%DAT2EDF Write a multichannel signal as a continuous EDF+ file.
%
% outputPath = dat2edf(signal, outputPath, channelNames, ...
%     samplingFrequency, recordingStartTime)
%
% outputPath = dat2edf(..., Overwrite=true, Units="uV")
%
% INPUTS
%   signal              Samples-by-channels numeric matrix in physical units.
%   outputPath          Output EDF file path. BIDS requires lowercase .edf.
%   channelNames        One unique label per signal column.
%   samplingFrequency   Sampling frequency in Hz.
%   recordingStartTime  MATLAB datetime scalar for the recording start.
%
% OPTIONS
%   Overwrite           Replace an existing EDF file. Default false.
%   Units               Physical unit per channel. Scalar values are expanded to all channels. Default "uV".
%   Patient             EDF patient field. Default "X" to avoid adding PHI.
%   Recording           EDF recording field. Default "BCI2000_to_BIDS".
%
% DEPENDENCY
%   MATLAB Signal Processing Toolbox (edfheader, edfwrite), R2021a or later.
%
% This function is intentionally independent from BCI2000_data. It receives
% an already prepared recording and only handles EDF-specific validation and
% serialization.

    arguments
        signal {mustBeNumeric, mustBeNonempty}
        outputPath (1,1) string
        channelNames (:,1) string
        samplingFrequency (1,1) double {mustBePositive, mustBeFinite}
        recordingStartTime (1,1) datetime
        options.Overwrite (1,1) logical = false
        options.Units string = "uV"
        options.Patient (1,1) string = "X"
        options.Recording (1,1) string = "BCI2000_to_BIDS"
    end

    if exist("edfheader", "file") ~= 2 || exist("edfwrite", "file") ~= 2
        error("dat2edf:MissingEDFSupport", ...
            ["edfheader/edfwrite were not found. EDF export requires the " ...
             "MATLAB Signal Processing Toolbox."]);
    end

    [outputFolder, ~, extension] = fileparts(outputPath);
    if ~strcmp(extension, ".edf")
        error("dat2edf:InvalidExtension", ...
            "BIDS EDF output must use the lowercase .edf extension.");
    end

    if strlength(outputFolder) > 0 && ~isfolder(outputFolder)
        [created, message] = mkdir(outputFolder);
        if ~created
            error("dat2edf:OutputDirectoryCreationFailed", ...
                "Could not create output directory '%s': %s", ...
                outputFolder, message);
        end
    end

    if isfile(outputPath)
        if options.Overwrite
            delete(outputPath);
        else
            error("dat2edf:OutputExists", ...
                ["The output EDF file already exists. Set Overwrite=true " ...
                 "to replace it: %s"], outputPath);
        end
    end

    signal = double(signal);
    [nSamples, nChannels] = size(signal);

    if numel(channelNames) ~= nChannels
        error("dat2edf:ChannelCountMismatch", ...
            ["The number of channel names (%d) does not match the number " ...
             "of signal columns (%d)."], numel(channelNames), nChannels);
    end

    if any(ismissing(channelNames) | strlength(channelNames) == 0)
        error("dat2edf:InvalidChannelNames", ...
            "All EDF channels must have non-empty names.");
    end

    if numel(unique(channelNames)) ~= nChannels
        error("dat2edf:DuplicateChannelNames", ...
            "EDF channel names must be unique.");
    end

    % EDF reserves 16 ASCII characters for each signal label.
    if any(strlength(channelNames) > 16)
        error("dat2edf:ChannelLabelTooLong", ...
            ["EDF signal labels are limited to 16 characters. Shorten the " ...
             "following channel labels before export: %s"], ...
            strjoin(channelNames(strlength(channelNames) > 16), ", "));
    end

    if any(cellfun(@(x) any(double(char(x)) > 127), cellstr(channelNames)))
        error("dat2edf:NonASCIIChannelLabel", ...
            "EDF signal labels must contain ASCII characters only.");
    end

    units = string(options.Units(:));
    if isscalar(units)
        units = repmat(units, nChannels, 1);
    elseif numel(units) ~= nChannels
        error("dat2edf:UnitCountMismatch", ...
            ["The number of unit labels (%d) does not match the number " ...
             "of signal columns (%d)."], numel(units), nChannels);
    end

    units(ismissing(units) | strlength(units) == 0) = "n/a";

    if any(strlength(units) > 8)
        error("dat2edf:UnitsTooLong", ...
            ["EDF physical dimensions are limited to 8 characters. " ...
             "Shorten the following units: %s"], ...
            strjoin(unique(units(strlength(units) > 8)), ", "));
    end

    if any(cellfun(@(x) any(double(char(x)) > 127), cellstr(units)))
        error("dat2edf:NonASCIIUnits", ...
            "EDF physical-dimension labels must contain ASCII characters only.");
    end

    if any(~isfinite(signal), "all")
        error("dat2edf:NonFiniteSignal", ...
            ["EDF cannot represent NaN or Inf samples in this exporter. " ...
             "Resolve non-finite samples before conversion."]);
    end

    % Choose a data-record layout close to one second without padding or
    % truncating samples. The samples per record must divide the total sample
    % count exactly. For typical BCI2000 recordings this resolves to fs samples
    % per record and therefore one-second EDF records.
    targetSamples = max(1, round(samplingFrequency));
    searchLimit = min(nSamples, max(targetSamples, 10 * targetSamples));
    candidates = 1:searchLimit;
    divisors = candidates(mod(nSamples, candidates) == 0);
    [~, nearestIndex] = min(abs(divisors - targetSamples));
    samplesPerRecord = divisors(nearestIndex);

    numDataRecords = nSamples / samplesPerRecord;
    dataRecordDuration = seconds(samplesPerRecord / samplingFrequency);

    physicalMin = min(signal, [], 1);
    physicalMax = max(signal, [], 1);

    % EDF physical min and max must define a non-zero range. Expand constant
    % channels by a very small symmetric interval without changing samples.
    constantChannels = physicalMin == physicalMax;
    if any(constantChannels)
        center = physicalMin(constantChannels);
        delta = max(abs(center) * 1e-6, 1e-6);
        physicalMin(constantChannels) = center - delta;
        physicalMax(constantChannels) = center + delta;
    end

    hdr = edfheader("EDF+");
    hdr.Patient = options.Patient;
    hdr.Recording = options.Recording;
    hdr.Reserved = "EDF+C";
    hdr.StartDate = string(recordingStartTime, "dd.MM.yy");
    hdr.StartTime = string(recordingStartTime, "HH.mm.ss");
    hdr.NumSignals = nChannels;
    hdr.NumDataRecords = numDataRecords;
    hdr.DataRecordDuration = dataRecordDuration;
    hdr.SignalLabels = channelNames(:).';
    hdr.PhysicalDimensions = units(:).';
    hdr.PhysicalMin = physicalMin;
    hdr.PhysicalMax = physicalMax;
    hdr.DigitalMin = repmat(-32768, 1, nChannels);
    hdr.DigitalMax = repmat(32767, 1, nChannels);

    % InputSampleType="physical" tells MATLAB to scale physical-valued data
    % into the 16-bit EDF digital range using the header min/max values.
    edfwrite(outputPath, hdr, signal, InputSampleType="physical");
end
