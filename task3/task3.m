function computeProtectionLevelsWithRa()
    % GNSS Position and Protection Level Calculator with RAIM
    % Refactored version with improved naming conventions and structure

    %% Constants and Configuration
    GNSS_DATA_FILE = 'navSolutionResults.mat';
    PSEUDORANGE_STD_DEV = 3;  % Standard deviation of pseudorange measurements (m)
    CHI_SQ_CONFIDENCE_LEVEL = 0.99;  % Confidence level for chi-square test
    PL_MISSED_DETECTION_PROB = 1e-7;  % Probability for protection level calculation
    
    %% Data Loading and Validation
    if ~exist(GNSS_DATA_FILE, 'file')
        error('GNSS data file not found: %s', GNSS_DATA_FILE);
    end
    
    navigationData = load(GNSS_DATA_FILE);  
    pseudoranges = navigationData.navSolutions.correctedP;
    satellitePositions = navigationData.navSolutions.satPositions;
    
    [numSatellites, numEpochs] = size(pseudoranges);
    validateDataDimensions(satellitePositions, numSatellites, numEpochs);
    
    %% Initialize Visualization
    initialize3DSatellitePositionPlot(numEpochs);
    
    %% Main Processing Loop
    for currentEpoch = 1:numEpochs
        [currentPseudoranges, currentSatPositions] = getEpochData(...
            pseudoranges, satellitePositions, currentEpoch);
        
        plotSatellitePositions(currentSatPositions, currentEpoch, numEpochs);
        
        designMatrix = computeDesignMatrix(currentSatPositions);
        initialWeights = eye(numSatellites);
        
        [positionEstimate, residuals] = computePositionEstimate(...
            designMatrix, initialWeights, currentPseudoranges);
        
        faultDetected = performRaFaultDetection(...
            residuals, initialWeights, numSatellites);
        
        protectionLevel = computeProtectionLevel(...
            PSEUDORANGE_STD_DEV, PL_MISSED_DETECTION_PROB);
        
        displayEpochResults(...
            currentEpoch, positionEstimate, protectionLevel, faultDetected);
    end
    
    finalize3DPlot(numEpochs);
end

%% Helper Functions
function validateDataDimensions(satPositions, expectedSats, expectedEpochs)
    actualDims = size(satPositions);
    if ~isequal(actualDims(2:3), [expectedSats, expectedEpochs])
        error(['Satellite position dimensions mismatch. Expected 3x%dx%d, '...
               'got 3x%dx%d'], expectedSats, expectedEpochs, ...
               actualDims(2), actualDims(3));
    end
end

function [pseudoranges, satPositions] = getEpochData(allPseudoranges, allSatPositions, epoch)
    pseudoranges = allPseudoranges(:, epoch);
    satPositions = squeeze(allSatPositions(:, :, epoch))';
    
    if any(isnan(satPositions(:)))
        error('Missing satellite position data at epoch %d', epoch);
    end
end

function designMatrix = computeDesignMatrix(satellitePositions)
    numSatellites = size(satellitePositions, 1);
    designMatrix = zeros(numSatellites, 4);
    
    for satIdx = 1:numSatellites
        positionVector = satellitePositions(satIdx, :);
        normDistance = norm(positionVector);
        
        if normDistance <= 0
            error('Zero-length satellite position vector at satellite %d', satIdx);
        end
        
        designMatrix(satIdx, 1:3) = positionVector / normDistance;
        designMatrix(satIdx, 4) = -1;  % For range equation
    end
end

function [position, residuals] = computePositionEstimate(A, W, pseudoranges)
    position = (A' * W * A) \ (A' * W * pseudoranges);
    residuals = pseudoranges - A * position;
end

function isFaultDetected = performRaFaultDetection(residuals, W, numSatellites)
    residualsVariance = (residuals' * residuals) / (numSatellites - 4);
    chiSquareStatistic = (residuals' * W * residuals) / residualsVariance;
    criticalValue = chi2inv(0.99, numSatellites - 4);
    isFaultDetected = chiSquareStatistic > criticalValue;
end

function protectionLevel = computeProtectionLevel(sigma, pmd)
    kFactor = chi2inv(1 - pmd, 1);
    protectionLevel = kFactor * sigma;
end

function displayEpochResults(epoch, position, pl, faultFlag)
    fprintf('Epoch %3d: Position = [%8.1f, %8.1f, %8.1f, %6.1f] | ', ...
            epoch, position(1), position(2), position(3), position(4));
    fprintf('PL = %5.2f m | ', pl);
    
    if faultFlag
        fprintf('FAULT DETECTED\n');
    else
        fprintf('Normal\n');
    end
end

function initialize3DSatellitePositionPlot(totalEpochs)
    figure;
    hold on;
    grid on;
    xlabel('X (m)');
    ylabel('Y (m)');
    zlabel('Z (m)');
    title('Satellite Visibility Across Epochs');
    axis equal;
end

function plotSatellitePositions(positions, epoch, totalEpochs)
    persistent cmap;
    
    if isempty(cmap)
        cmap = parula(totalEpochs);
    end
    
    scatter3(positions(:, 1), positions(:, 2), positions(:, 3), ...
             50, cmap(epoch, :), 'filled');
end

function finalize3DPlot(totalEpochs)
    colormap(parula(totalEpochs));
    c = colorbar;
    c.Label.String = 'Epoch Index';
    caxis([1 totalEpochs]);
    hold off;
end
