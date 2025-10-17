// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title MXGD - MaxGold Gold-Backed Commodity Token
 * @notice 1 MXGD = 1 gram of .9999 fine gold from BioMilling LLC mine
 * @dev This is MY mine, MY token, MY empire. Built for market domination.
 * 
 * PRODUCTION FLOW:
 * BioMilling Mine → Gold Doré → Refinery Partner → .9999 Fine Gold → MXGD Tokens
 * 
 * LEGAL DEFENSES (5 LAYERS):
 * 1. SEC April 2025 covered stablecoin guidance (commodity-backed)
 * 2. CFTC commodity jurisdiction (gold = commodity)
 * 3. Fails all 4 Howey Test prongs
 * 4. Sufficient decentralization (DAO governance later)
 * 5. Ripple programmatic sales (exchange distribution)
 * 
 * CURRENT STATUS: October 17, 2025
 * - Gold price: $4,320/oz ($138.89/gram)
 * - Mine reserves: $1.5B (proven)
 * - Mine status: Restarting operations with SAFT funding
 * - Refinery partner: [TBD - within 50 miles of mine]
 */
contract MXGD is ERC20, AccessControl, Pausable, ReentrancyGuard {
    
    // ============ ROLES ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant REFINERY_ROLE = keccak256("REFINERY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    // ============ STATE VARIABLES ============
    
    /// @notice Total grams of .9999 fine gold backing all tokens
    uint256 public totalGoldReserves;
    
    /// @notice Gold price tracking (for transparency, not minting control)
    uint256 public lastRecordedGoldPrice; // In cents per gram ($138.89 = 13889)
    uint256 public lastPriceUpdate;
    
    /// @notice Mine production tracking
    uint256 public totalDoreProduced; // Grams of doré from mine
    uint256 public totalRefinedGold; // Grams of .9999 gold from refinery
    
    /// @notice Refinery partner information
    struct RefineryPartner {
        address refineryAddress;
        string refineryName;
        string location;
        bool active;
        uint256 totalProcessed; // Grams of gold refined
        uint256 addedTimestamp;
    }
    mapping(uint256 => RefineryPartner) public refineries;
    uint256 public refineryCount;
    
    /// @notice Gold batch tracking (from mine → refinery → tokens)
    struct GoldBatch {
        uint256 batchId;
        uint256 doreWeight; // Grams of doré from mine
        uint256 refinedWeight; // Grams of .9999 gold after refining
        uint256 refineryId;
        string[] barSerials; // Serial numbers of refined bars
        uint256 minedTimestamp;
        uint256 refinedTimestamp;
        uint256 tokenizedTimestamp;
        bool tokenized;
    }
    mapping(uint256 => GoldBatch) public goldBatches;
    uint256 public batchCount;
    
    /// @notice Regulation S compliance (1-year U.S. exclusion)
    uint256 public immutable REG_S_RESTRICTION_PERIOD = 365 days;
    uint256 public immutable launchTime;
    
    /// @notice Compliance mappings
    mapping(address => bool) public isRestricted; // U.S. persons during Reg S
    mapping(address => bool) public isWhitelisted; // KYC verified non-U.S.
    mapping(address => uint256) public acquisitionTime; // For Reg S tracking
    
    /// @notice Redemption system
    struct RedemptionRequest {
        uint256 requestId;
        address requester;
        uint256 amount; // Grams of gold
        bool isPhysical; // true = physical gold, false = cash
        string deliveryAddress;
        uint256 refineryId; // Which refinery handles redemption
        uint256 requestTimestamp;
        uint256 fulfillmentTimestamp;
        bool fulfilled;
        bool cancelled;
    }
    mapping(uint256 => RedemptionRequest) public redemptionRequests;
    uint256 public redemptionCount;
    
    /// @notice Redemption fees (in basis points, 50 = 0.5%)
    uint256 public cashRedemptionFee = 50; // 0.5%
    uint256 public physicalRedemptionFeeSmall = 200; // 2% for <3000g
    uint256 public physicalRedemptionFeeLarge = 50; // 0.5% for ≥3000g
    
    /// @notice Redemption minimums (in grams)
    uint256 public minCashRedemption = 10; // 10g = ~$1,390
    uint256 public minPhysicalSmall = 100; // 100g = ~$13,900
    uint256 public minPhysicalLarge = 3000; // 3000g = ~$417,000
    
    /// @notice Proof of reserves
    address public proofOfReservesOracle;
    uint256 public lastAuditTimestamp;
    string public lastAuditReportURI; // IPFS hash of audit report
    
    /// @notice Emergency controls
    bool public emergencyShutdown;
    bool public mintingPaused;
    
    // ============ EVENTS ============
    
    event GoldBatchReceived(
        uint256 indexed batchId,
        uint256 doreWeight,
        uint256 minedTimestamp
    );
    
    event GoldBatchRefined(
        uint256 indexed batchId,
        uint256 refinedWeight,
        uint256 indexed refineryId,
        string[] barSerials
    );
    
    event TokensMinted(
        uint256 indexed batchId,
        address indexed recipient,
        uint256 amount,
        uint256 goldBacking
    );
    
    event RefineryAdded(
        uint256 indexed refineryId,
        string refineryName,
        string location
    );
    
    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed requester,
        uint256 amount,
        bool isPhysical,
        uint256 refineryId
    );
    
    event RedemptionFulfilled(
        uint256 indexed requestId,
        address indexed requester,
        uint256 amount,
        uint256 fee
    );
    
    event RedemptionCancelled(
        uint256 indexed requestId,
        address indexed requester
    );
    
    event ReservesAudited(
        uint256 totalGoldGrams,
        uint256 totalTokens,
        uint256 backingRatio, // Basis points, 10000 = 100%
        uint256 timestamp,
        string reportURI
    );
    
    event GoldPriceUpdated(
        uint256 priceInCents,
        uint256 timestamp
    );
    
    event WhitelistUpdated(address indexed account, bool status);
    event RestrictedAddressUpdated(address indexed account, bool status);
    event EmergencyShutdownActivated(uint256 timestamp);
    event MintingPausedToggled(bool paused);
    
    // ============ MODIFIERS ============
    
    modifier onlyWhitelisted(address account) {
        require(isWhitelisted[account], "MXGD: Account not KYC verified");
        _;
    }
    
    modifier notRestricted(address account) {
        require(!isRestricted[account], "MXGD: U.S. persons restricted");
        _;
    }
    
    modifier notEmergencyShutdown() {
        require(!emergencyShutdown, "MXGD: Emergency shutdown active");
        _;
    }
    
    modifier mintingNotPaused() {
        require(!mintingPaused, "MXGD: Minting currently paused");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(
        address admin,
        address minter,
        address compliance,
        uint256 initialGoldPrice // In cents per gram
    ) ERC20("MaxGold", "MXGD") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
        _grantRole(COMPLIANCE_ROLE, compliance);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(BURNER_ROLE, minter);
        
        launchTime = block.timestamp;
        lastRecordedGoldPrice = initialGoldPrice;
        lastPriceUpdate = block.timestamp;
    }
    
    // ============ REFINERY MANAGEMENT ============
    
    /**
     * @notice Add refinery partner
     * @dev Only admin can add refineries. These are our strategic partners.
     */
    function addRefinery(
        address refineryAddress,
        string calldata refineryName,
        string calldata location
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        refineryCount++;
        
        refineries[refineryCount] = RefineryPartner({
            refineryAddress: refineryAddress,
            refineryName: refineryName,
            location: location,
            active: true,
            totalProcessed: 0,
            addedTimestamp: block.timestamp
        });
        
        _grantRole(REFINERY_ROLE, refineryAddress);
        
        emit RefineryAdded(refineryCount, refineryName, location);
    }
    
    /**
     * @notice Deactivate refinery (if partnership ends)
     */
    function deactivateRefinery(uint256 refineryId) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(refineryId <= refineryCount, "MXGD: Invalid refinery ID");
        refineries[refineryId].active = false;
    }
    
    // ============ GOLD BATCH PROCESSING ============
    
    /**
     * @notice Record gold doré received from mine
     * @dev Called when mine delivers doré to refinery
     */
    function recordDoreDelivery(
        uint256 doreWeight
    ) external onlyRole(MINTER_ROLE) returns (uint256) {
        require(doreWeight > 0, "MXGD: Invalid weight");
        
        batchCount++;
        totalDoreProduced += doreWeight;
        
        goldBatches[batchCount] = GoldBatch({
            batchId: batchCount,
            doreWeight: doreWeight,
            refinedWeight: 0,
            refineryId: 0,
            barSerials: new string[](0),
            minedTimestamp: block.timestamp,
            refinedTimestamp: 0,
            tokenizedTimestamp: 0,
            tokenized: false
        });
        
        emit GoldBatchReceived(batchCount, doreWeight, block.timestamp);
        
        return batchCount;
    }
    
    /**
     * @notice Record refined gold from refinery
     * @dev Called by refinery after processing doré → .9999 fine gold
     */
    function recordRefinedGold(
        uint256 batchId,
        uint256 refinedWeight,
        uint256 refineryId,
        string[] calldata barSerials
    ) external onlyRole(REFINERY_ROLE) {
        require(batchId <= batchCount, "MXGD: Invalid batch");
        require(refineryId <= refineryCount, "MXGD: Invalid refinery");
        require(refineries[refineryId].active, "MXGD: Refinery not active");
        
        GoldBatch storage batch = goldBatches[batchId];
        require(batch.refinedWeight == 0, "MXGD: Already refined");
        require(refinedWeight > 0, "MXGD: Invalid weight");
        
        // Refined weight should be ~90-95% of doré weight (typical recovery)
        require(
            refinedWeight <= batch.doreWeight,
            "MXGD: Refined exceeds doré"
        );
        
        batch.refinedWeight = refinedWeight;
        batch.refineryId = refineryId;
        batch.barSerials = barSerials;
        batch.refinedTimestamp = block.timestamp;
        
        totalRefinedGold += refinedWeight;
        refineries[refineryId].totalProcessed += refinedWeight;
        
        emit GoldBatchRefined(batchId, refinedWeight, refineryId, barSerials);
    }
    
    // ============ TOKEN MINTING ============
    
    /**
     * @notice Mint MXGD tokens backed by refined gold
     * @dev Can only mint after gold is refined. This is the critical control.
     */
    function mint(
        address to,
        uint256 amount, // Amount in grams (1 token = 1 gram with 18 decimals)
        uint256 batchId
    ) 
        external 
        onlyRole(MINTER_ROLE)
        onlyWhitelisted(to)
        notRestricted(to)
        notEmergencyShutdown
        mintingNotPaused
    {
        require(amount > 0, "MXGD: Amount must be positive");
        require(batchId <= batchCount, "MXGD: Invalid batch");
        
        GoldBatch storage batch = goldBatches[batchId];
        require(batch.refinedWeight > 0, "MXGD: Batch not refined yet");
        require(!batch.tokenized, "MXGD: Batch already tokenized");
        require(amount <= batch.refinedWeight, "MXGD: Exceeds batch weight");
        
        // Update state
        batch.tokenized = true;
        batch.tokenizedTimestamp = block.timestamp;
        totalGoldReserves += amount;
        acquisitionTime[to] = block.timestamp;
        
        // Mint tokens (amount in grams, with 18 decimals)
        _mint(to, amount * 10**decimals());
        
        emit TokensMinted(batchId, to, amount, amount);
    }
    
    /**
     * @notice Pause/unpause minting (emergency control)
     */
    function toggleMintingPause() external onlyRole(PAUSER_ROLE) {
        mintingPaused = !mintingPaused;
        emit MintingPausedToggled(mintingPaused);
    }
    
    // ============ REDEMPTION SYSTEM ============
    
    /**
     * @notice Request redemption for gold
     * @param amount Amount in grams
     * @param isPhysical true = physical gold bars, false = cash settlement
     * @param deliveryAddress Physical address (if applicable)
     * @param refineryId Which refinery handles redemption
     */
    function requestRedemption(
        uint256 amount,
        bool isPhysical,
        string calldata deliveryAddress,
        uint256 refineryId
    ) external nonReentrant notEmergencyShutdown {
        require(amount > 0, "MXGD: Amount must be positive");
        require(refineryId <= refineryCount, "MXGD: Invalid refinery");
        require(refineries[refineryId].active, "MXGD: Refinery not active");
        
        // Check minimums
        if (!isPhysical) {
            require(amount >= minCashRedemption, "MXGD: Below cash minimum");
        } else if (amount < minPhysicalLarge) {
            require(amount >= minPhysicalSmall, "MXGD: Below physical minimum");
        }
        
        // Check balance
        require(
            balanceOf(msg.sender) >= amount * 10**decimals(),
            "MXGD: Insufficient balance"
        );
        
        // Burn tokens immediately
        _burn(msg.sender, amount * 10**decimals());
        totalGoldReserves -= amount;
        
        // Create redemption request
        redemptionCount++;
        redemptionRequests[redemptionCount] = RedemptionRequest({
            requestId: redemptionCount,
            requester: msg.sender,
            amount: amount,
            isPhysical: isPhysical,
            deliveryAddress: deliveryAddress,
            refineryId: refineryId,
            requestTimestamp: block.timestamp,
            fulfillmentTimestamp: 0,
            fulfilled: false,
            cancelled: false
        });
        
        emit RedemptionRequested(
            redemptionCount,
            msg.sender,
            amount,
            isPhysical,
            refineryId
        );
    }
    
    /**
     * @notice Fulfill redemption (called after gold/cash delivered)
     */
    function fulfillRedemption(uint256 requestId) 
        external 
        onlyRole(MINTER_ROLE) 
    {
        require(requestId <= redemptionCount, "MXGD: Invalid request");
        RedemptionRequest storage request = redemptionRequests[requestId];
        require(!request.fulfilled, "MXGD: Already fulfilled");
        require(!request.cancelled, "MXGD: Request cancelled");
        
        request.fulfilled = true;
        request.fulfillmentTimestamp = block.timestamp;
        
        // Calculate fee
        uint256 fee;
        if (!request.isPhysical) {
            fee = (request.amount * cashRedemptionFee) / 10000;
        } else if (request.amount >= minPhysicalLarge) {
            fee = (request.amount * physicalRedemptionFeeLarge) / 10000;
        } else {
            fee = (request.amount * physicalRedemptionFeeSmall) / 10000;
        }
        
        emit RedemptionFulfilled(requestId, request.requester, request.amount, fee);
    }
    
    /**
     * @notice Cancel redemption request (refund tokens)
     */
    function cancelRedemption(uint256 requestId) external {
        require(requestId <= redemptionCount, "MXGD: Invalid request");
        RedemptionRequest storage request = redemptionRequests[requestId];
        require(request.requester == msg.sender, "MXGD: Not your request");
        require(!request.fulfilled, "MXGD: Already fulfilled");
        require(!request.cancelled, "MXGD: Already cancelled");
        
        request.cancelled = true;
        
        // Refund tokens
        _mint(msg.sender, request.amount * 10**decimals());
        totalGoldReserves += request.amount;
        
        emit RedemptionCancelled(requestId, msg.sender);
    }
    
    // ============ COMPLIANCE FUNCTIONS ============
    
    function setWhitelist(address account, bool status) 
        external 
        onlyRole(COMPLIANCE_ROLE) 
    {
        isWhitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }
    
    function setRestricted(address account, bool status) 
        external 
        onlyRole(COMPLIANCE_ROLE) 
    {
        isRestricted[account] = status;
        emit RestrictedAddressUpdated(account, status);
    }
    
    function batchSetWhitelist(address[] calldata accounts, bool status) 
        external 
        onlyRole(COMPLIANCE_ROLE) 
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            isWhitelisted[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }
    
    function isRegSPeriodEnded() public view returns (bool) {
        return block.timestamp >= launchTime + REG_S_RESTRICTION_PERIOD;
    }
    
    // ============ TRANSFER OVERRIDES (REG S COMPLIANCE) ============
    
    function transfer(address to, uint256 amount) 
        public 
        virtual 
        override 
        whenNotPaused 
        notEmergencyShutdown
        returns (bool) 
    {
        if (!isRegSPeriodEnded()) {
            require(isWhitelisted[to], "MXGD: Recipient not whitelisted");
            require(!isRestricted[to], "MXGD: Cannot transfer to restricted");
        }
        
        acquisitionTime[to] = block.timestamp;
        return super.transfer(to, amount);
    }
    
    function transferFrom(address from, address to, uint256 amount) 
        public 
        virtual 
        override 
        whenNotPaused 
        notEmergencyShutdown
        returns (bool) 
    {
        if (!isRegSPeriodEnded()) {
            require(isWhitelisted[to], "MXGD: Recipient not whitelisted");
            require(!isRestricted[to], "MXGD: Cannot transfer to restricted");
        }
        
        acquisitionTime[to] = block.timestamp;
        return super.transferFrom(from, to, amount);
    }
    
    // ============ AUDIT & TRANSPARENCY ============
    
    function updateProofOfReserves(
        uint256 auditedGrams,
        string calldata reportURI
    ) external onlyRole(COMPLIANCE_ROLE) {
        uint256 totalSupplyGrams = totalSupply() / 10**decimals();
        
        require(
            auditedGrams >= totalSupplyGrams,
            "MXGD: Insufficient reserves"
        );
        
        lastAuditTimestamp = block.timestamp;
        lastAuditReportURI = reportURI;
        
        uint256 backingRatio = (auditedGrams * 10000) / totalSupplyGrams;
        
        emit ReservesAudited(
            auditedGrams,
            totalSupplyGrams,
            backingRatio,
            block.timestamp,
            reportURI
        );
    }
    
    function setProofOfReservesOracle(address oracle) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        proofOfReservesOracle = oracle;
    }
    
    function updateGoldPrice(uint256 priceInCents) 
        external 
        onlyRole(COMPLIANCE_ROLE) 
    {
        lastRecordedGoldPrice = priceInCents;
        lastPriceUpdate = block.timestamp;
        emit GoldPriceUpdated(priceInCents, block.timestamp);
    }
    
    function getReserveRatio() external view returns (uint256) {
        uint256 totalSupplyGrams = totalSupply() / 10**decimals();
        if (totalSupplyGrams == 0) return 0;
        return (totalGoldReserves * 10000) / totalSupplyGrams;
    }
    
    // ============ REDEMPTION FEE MANAGEMENT ============
    
    function updateRedemptionFees(
        uint256 _cashFee,
        uint256 _physicalSmallFee,
        uint256 _physicalLargeFee
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_cashFee <= 200, "MXGD: Cash fee too high"); // Max 2%
        require(_physicalSmallFee <= 500, "MXGD: Small fee too high"); // Max 5%
        require(_physicalLargeFee <= 200, "MXGD: Large fee too high"); // Max 2%
        
        cashRedemptionFee = _cashFee;
        physicalRedemptionFeeSmall = _physicalSmallFee;
        physicalRedemptionFeeLarge = _physicalLargeFee;
    }
    
    function updateRedemptionMinimums(
        uint256 _minCash,
        uint256 _minPhysicalSmall,
        uint256 _minPhysicalLarge
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minCashRedemption = _minCash;
        minPhysicalSmall = _minPhysicalSmall;
        minPhysicalLarge = _minPhysicalLarge;
    }
    
    // ============ EMERGENCY FUNCTIONS ============
    
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    function activateEmergencyShutdown() 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        emergencyShutdown = true;
        _pause();
        emit EmergencyShutdownActivated(block.timestamp);
    }
    
    // ============ VIEW FUNCTIONS ============
    
    function getGoldBatch(uint256 batchId) 
        external 
        view 
        returns (GoldBatch memory) 
    {
        require(batchId <= batchCount, "MXGD: Invalid batch");
        return goldBatches[batchId];
    }
    
    function getRedemptionRequest(uint256 requestId) 
        external 
        view 
        returns (RedemptionRequest memory) 
    {
        require(requestId <= redemptionCount, "MXGD: Invalid request");
        return redemptionRequests[requestId];
    }
    
    function getRefinery(uint256 refineryId) 
        external 
        view 
        returns (RefineryPartner memory) 
    {
        require(refineryId <= refineryCount, "MXGD: Invalid refinery");
        return refineries[refineryId];
    }
    
    function canReceiveTokens(address account) external view returns (bool) {
        if (isRegSPeriodEnded()) return true;
        return isWhitelisted[account] && !isRestricted[account];
    }
    
    /**
     * @notice Get current gold price in dollars
     * @dev Divides cents by 100 for display purposes
     */
    function getCurrentGoldPriceUSD() external view returns (uint256) {
        return lastRecordedGoldPrice / 100; // Returns dollars
    }
}
