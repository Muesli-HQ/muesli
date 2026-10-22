import Foundation
import llama
@_exported import LLMMacros

public enum ThinkingMode: Sendable {
    case none
    case suppressed
    case enabled
}

/// A token used by the language model.
public typealias Token = llama_token

/// A batch of tokens for processing.
public typealias Batch = llama_batch

/// A pointer to the underlying model.
public typealias Model = OpaquePointer

/// A pointer to the model's vocabulary.
public typealias Vocab = OpaquePointer

/// A chat message consisting of a role and content.
public typealias Chat = (role: Role, content: String)


/// Core actor responsible for thread-safe interactions with the llama.cpp library.
///
/// `LLMCore` handles low-level operations including token encoding/decoding,
/// context management, and inference. It ensures thread safety by using Swift's
/// actor isolation.
public actor LLMCore {
    private let model: Model
    private let vocab: Vocab
    private var context: OpaquePointer
    private var batch: llama_batch
    private let params: llama_context_params
    
    private(set) var seed: UInt32
    private(set) var topK: Int32
    private(set) var topP: Float
    private(set) var temp: Float
    private(set) var repeatPenalty: Float
    private(set) var repetitionLookback: Int32
    
    private let maxTokenCount: Int
    private let totalTokenCount: Int
    
    public lazy var newlineToken: Token = llama_vocab_nl(vocab)
    public lazy var endOfTurnToken: Token = llama_vocab_eot(vocab)
    public lazy var separatorToken: Token = llama_vocab_sep(vocab)
    public lazy var paddingToken: Token = llama_vocab_pad(vocab)
    
    private lazy var startToken: Token = llama_vocab_bos(vocab)
    private lazy var endToken: Token = llama_vocab_eos(vocab)
    private lazy var nullToken: Token = encode("\0", shouldAddBOS: false).first!
    private lazy var quoteToken: Token = encode("\"", shouldAddBOS: false, special: false).first!
    private lazy var whitespaceToken: Token = encode(" ", shouldAddBOS: false, special: false).first!
    
    private var thinkingStartTokens: [Token]?
    private var thinkingEndTokens: [Token]?
    private var thinkingStartMarker: String?
    private var thinkingEndMarker: String?
    
    private var stopSequenceTokens: [Token]?
    private var tokenBuffer: [Token] = []
    private let tokenDecodeCache = NSCache<NSNumber, NSString>()
    
    private var shouldContinuePredicting = false
    private var currentTokenCount: Int32 = 0
    private(set) var lastCompletionTokenCount = 0
    private var debugLastGeneratedTokens: [Token] = []
    
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    
    func setParameters(seed: UInt32? = nil, topK: Int32? = nil, topP: Float? = nil, temp: Float? = nil, repeatPenalty: Float? = nil, repetitionLookback: Int32? = nil) {
        if let seed { self.seed = seed }
        if let topK { self.topK = topK }
        if let topP { self.topP = topP }
        if let temp { self.temp = temp }
        if let repeatPenalty { self.repeatPenalty = repeatPenalty }
        if let repetitionLookback { self.repetitionLookback = repetitionLookback }
        
        if seed != nil || topK != nil || topP != nil || temp != nil || repeatPenalty != nil || repetitionLookback != nil {
            recreateSampler()
        }
    }
    
    func setStopSequence(_ sequence: String?) {
        if let sequence {
            stopSequenceTokens = encode(sequence, shouldAddBOS: false)
        } else {
            stopSequenceTokens = nil
        }
    }
    
    func setThinkingTokens(start: [Token]?, end: [Token]?, startMarker: String?, endMarker: String?) {
        thinkingStartTokens = start
        thinkingEndTokens = end
        thinkingStartMarker = startMarker
        thinkingEndMarker = endMarker
    }
    
    private func recreateSampler() {
        if let sampler {
            llama_sampler_free(sampler)
        }
        
        let samplerParams = llama_sampler_chain_default_params()
        sampler = llama_sampler_chain_init(samplerParams)
        
        llama_sampler_chain_add(sampler!, llama_sampler_init_penalties(repetitionLookback, repeatPenalty, 0, 0))
        llama_sampler_chain_add(sampler!, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(sampler!, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(sampler!, llama_sampler_init_temp(temp))
        llama_sampler_chain_add(sampler!, llama_sampler_init_dist(seed))
    }
    
    public init(model: Model, path: [CChar], seed: UInt32, topK: Int32, topP: Float, temp: Float, repeatPenalty: Float, repetitionLookback: Int32, maxTokenCount: Int) throws {
        LLM.ensureInitialized()
        self.model = model
        self.vocab = llama_model_get_vocab(model)
        self.seed = seed
        self.topK = topK
        self.topP = topP
        self.temp = temp
        self.repeatPenalty = repeatPenalty
        self.repetitionLookback = repetitionLookback
        self.maxTokenCount = maxTokenCount
        self.totalTokenCount = Int(llama_vocab_n_tokens(vocab))
        
        var contextParams = llama_context_default_params()
        let processorCount = Int32(ProcessInfo().processorCount)
        contextParams.n_ctx = UInt32(maxTokenCount)
        contextParams.n_batch = contextParams.n_ctx
        contextParams.n_threads = processorCount
        contextParams.n_threads_batch = processorCount
        contextParams.embeddings = true
        self.params = contextParams
        
        guard let context = llama_init_from_model(model, params) else {
            throw LLMError.contextCreationFailed
        }
        self.context = context
        
        self.batch = llama_batch_init(Int32(maxTokenCount), 0, 1)
        
        recreateSampler()
    }
    
    deinit {
        llama_batch_free(batch)
        llama_free(context)
        if let sampler {
            llama_sampler_free(sampler)
        }
        llama_model_free(model)
    }
    
    
    public func encode(_ text: String, shouldAddBOS: Bool = true, special: Bool = true) -> [Token] {
        let count = Int32(text.utf8.count)
        var tokenCount = count + 1
        let cTokens = UnsafeMutablePointer<llama_token>.allocate(capacity: Int(tokenCount))
        defer { cTokens.deallocate() }
        
        tokenCount = llama_tokenize(vocab, text, count, cTokens, tokenCount, shouldAddBOS, special)
        let tokens = (0..<Int(tokenCount)).map { cTokens[$0] }
        return tokens
    }
    
    public func decode(_ token: Token, special: Bool = false) -> String {
        let cacheKey = special ? token + Int32(totalTokenCount) : token
        if let cached = tokenDecodeCache.object(forKey: NSNumber(value: cacheKey)) {
            return cached as String
        }
        
        var bufferLength = 16
        var buffer: [CChar] = .init(repeating: 0, count: bufferLength)
        var actualLength = Int(llama_token_to_piece(vocab, token, &buffer, Int32(bufferLength), 0, special))
        
        guard actualLength != 0 else { return "" }
        
        if actualLength < 0 {
            bufferLength = -actualLength
            buffer = .init(repeating: 0, count: bufferLength)
            actualLength = Int(llama_token_to_piece(vocab, token, &buffer, Int32(bufferLength), 0, special))
            guard actualLength > 0 else { return "" }
        }
        
        let validBuffer = Array(buffer.prefix(actualLength))
        let bytes = validBuffer.map { UInt8(bitPattern: $0) }
        guard var decoded = String(bytes: bytes, encoding: .utf8) else { return "" }
        
        if decoded.contains("\0") {
            decoded = decoded.filter { $0 != "\0" }
        }
        
        tokenDecodeCache.setObject(decoded as NSString, forKey: NSNumber(value: cacheKey))
        
        return decoded
    }
    
    public func getChatTemplateHint() -> String? {
        guard let template = llama_model_chat_template(model, nil) else { return nil }
        return String(cString: template)
    }
    
    
    func prepareContext(for input: String) -> Bool {
        guard !input.isEmpty else { return false }
        
        tokenBuffer.removeAll()
        
        var tokens = encode(input)
        if tokens.last == nullToken { tokens.removeLast() }
        
        let initialCount = tokens.count
        guard maxTokenCount > initialCount + Int(currentTokenCount) else { return false }
        
        clearBatch()
        for (i, token) in tokens.enumerated() {
            addToBatch(token: token, pos: currentTokenCount + Int32(i), isLogit: i == initialCount - 1)
        }
        guard llama_decode(context, batch) == 0 else { return false }
        
        currentTokenCount += Int32(initialCount)
        shouldContinuePredicting = true
        return true
    }
    
    private func clearBatch() {
        batch.n_tokens = 0
    }
    
    private func addToBatch(token: Token, pos: Int32, isLogit: Bool = true) {
        let i = Int(batch.n_tokens)
        batch.token[i] = token
        batch.pos[i] = pos
        batch.n_seq_id[i] = 1
        if let seq_id = batch.seq_id[i] {
            seq_id[0] = 0
        }
        batch.logits[i] = isLogit ? 1 : 0
        batch.n_tokens += 1
    }
    
    func predictNextToken(excluding: [Token] = []) -> Token {
        guard shouldContinuePredicting, currentTokenCount < Int32(maxTokenCount) else {
            return endToken
        }
        
        guard let sampler = sampler else { return endToken }
        
        let batchIndex = batch.n_tokens - 1
        
        if !excluding.isEmpty, let logits = llama_get_logits_ith(context, batchIndex) {
            for token in excluding {
                logits[Int(token)] = -.infinity
            }
        }
        
        let token = llama_sampler_sample(sampler, context, batchIndex)
        
        if token == endToken {
            return endToken
        }
        
        llama_sampler_accept(sampler, token)
        
        tokenBuffer.append(token)
        
        if let stopTokens = stopSequenceTokens, stopTokens.count <= tokenBuffer.count {
            let startIdx = tokenBuffer.count - stopTokens.count
            let bufferSlice = tokenBuffer[startIdx..<tokenBuffer.count]
            if Array(bufferSlice) == stopTokens {
                shouldContinuePredicting = false
                return endToken
            }
        }
        
        clearBatch()
        addToBatch(token: token, pos: currentTokenCount)
        
        if llama_decode(context, batch) != 0 {
            shouldContinuePredicting = false
            return endToken
        }
        
        currentTokenCount += 1
        return token
    }
    
    func stopGeneration() {
        shouldContinuePredicting = false
    }
    
    private func injectTokensIntoContext(_ tokens: [Token]) -> Bool {
        for token in tokens {
            if let sampler {
                llama_sampler_accept(sampler, token)
            }
            clearBatch()
            addToBatch(token: token, pos: currentTokenCount)
            guard llama_decode(context, batch) == 0 else {
                shouldContinuePredicting = false
                return false
            }
            currentTokenCount += 1
        }
        return true
    }
    
    func resetContext() {
        currentTokenCount = 0
        tokenBuffer.removeAll()
        shouldContinuePredicting = false
        let memory = llama_get_memory(context)
        if llama_model_is_hybrid(model) || llama_model_is_recurrent(model) {
            llama_memory_clear(memory, false)
        } else {
            llama_memory_seq_rm(memory, -1, -1, -1)
        }
    }
    
    func generateResponseStream(from input: String, thinking: ThinkingMode = .none, maxNewTokens: Int? = nil) -> AsyncStream<String> {
        generateResponseStreamWithThinking(from: input, thinking: thinking, maxNewTokens: maxNewTokens).response
    }
    
    func generateThinkingStream(from input: String) -> AsyncStream<String> {
        generateResponseStreamWithThinking(from: input, thinking: .enabled).thinking
    }
    
    func generateResponseStreamWithThinking(from input: String, thinking thinkingMode: ThinkingMode = .none, maxNewTokens: Int? = nil) -> (thinking: AsyncStream<String>, response: AsyncStream<String>) {
        var thinkingContinuation: AsyncStream<String>.Continuation!
        var responseContinuation: AsyncStream<String>.Continuation!
        
        let thinkingStream = AsyncStream<String> { thinkingContinuation = $0 }
        let responseStream = AsyncStream<String> { responseContinuation = $0 }
        
        Task {
            guard prepareContext(for: input) else {
                thinkingContinuation.finish()
                responseContinuation.finish()
                return
            }
            
            if let sampler { llama_sampler_reset(sampler) }
            
            let startMarker = thinkingStartMarker
            let endMarker = thinkingEndMarker
            let maxPendingLength = max(startMarker?.count ?? 0, endMarker?.count ?? 0)
            
            var currentlyInThinkingPhase = thinkingMode == .enabled && startMarker != nil
            var shouldGuaranteeOutput = true
            var pendingText = ""
            
            func stream(_ text: String) {
                guard !text.isEmpty else { return }
                if currentlyInThinkingPhase {
                    thinkingContinuation.yield(text)
                } else {
                    responseContinuation.yield(text)
                }
            }
            
            func streamPendingText() {
                stream(pendingText)
                pendingText = ""
            }
            
            func finishAllStreams() {
                thinkingContinuation.finish()
                responseContinuation.finish()
            }
            
            func transitionToResponsePhase() {
                streamPendingText()
                currentlyInThinkingPhase = false
                shouldGuaranteeOutput = true
                thinkingContinuation.finish()
            }
            
            func foundThinkingStartMarker() -> Bool {
                guard let marker = startMarker, pendingText.hasSuffix(marker) else { return false }
                pendingText.removeLast(marker.count)
                streamPendingText()
                currentlyInThinkingPhase = true
                return true
            }
            
            func foundThinkingEndMarker() -> Bool {
                guard let marker = endMarker, pendingText.hasSuffix(marker) else { return false }
                pendingText.removeLast(marker.count)
                transitionToResponsePhase()
                return true
            }
            
            func streamOldestPendingTextIfNeeded() {
                guard pendingText.count > maxPendingLength else { return }
                let overflowLength = pendingText.count - maxPendingLength
                stream(String(pendingText.prefix(overflowLength)))
                pendingText.removeFirst(overflowLength)
            }
            
            var generatedTokenCount = 0
            lastCompletionTokenCount = 0
            defer { lastCompletionTokenCount = generatedTokenCount }
            let generationBudget = maxNewTokens.map { max(0, $0) } ?? Int.max
            while shouldContinuePredicting && currentTokenCount < Int32(maxTokenCount)
                && generatedTokenCount < generationBudget {
                let excludedTokens = shouldGuaranteeOutput ? [endToken] : []
                let token = predictNextToken(excluding: excludedTokens)
                generatedTokenCount += 1
                shouldGuaranteeOutput = false
                
                let reachedEndOfGeneration = token == endToken
                
                if reachedEndOfGeneration {
                    let stuckInThinkingPhase = currentlyInThinkingPhase && thinkingEndTokens != nil
                    
                    if stuckInThinkingPhase {
                        let injectedSuccessfully = injectTokensIntoContext(thinkingEndTokens! + [newlineToken])
                        guard injectedSuccessfully else {
                            finishAllStreams()
                            return
                        }
                        transitionToResponsePhase()
                        continue
                    }
                    
                    streamPendingText()
                    finishAllStreams()
                    return
                }
                
                pendingText += decode(token)
                
                let detectingThinkingMarkers = thinkingMode != .none
                
                if detectingThinkingMarkers {
                    if foundThinkingStartMarker() { continue }
                    if foundThinkingEndMarker() { continue }
                }
                
                streamOldestPendingTextIfNeeded()
            }
            
            streamPendingText()
            finishAllStreams()
        }
        
        return (thinkingStream, responseStream)
    }
    
    func getEmbeddings(from input: String) throws -> [Float] {
        guard !input.isEmpty else { throw LLMError.inputTooLong }
        
        llama_set_embeddings(context, true)
        defer { 
            llama_set_embeddings(context, false)
        }
        
        llama_memory_clear(llama_get_memory(context), false)
        
        let cleanTokens = prepareTokensForEmbeddings(from: input)
        try processBatchForEmbeddings(cleanTokens)
        
        let embeddings = try extractEmbeddingsFromContext()
        
        llama_memory_clear(llama_get_memory(context), false)
        
        return embeddings
    }
    
    private func prepareTokensForEmbeddings(from input: String) -> [Token] {
        var tokens = encode(input)
        if tokens.last == nullToken { tokens.removeLast() }
        return tokens
    }
    
    private func processBatchForEmbeddings(_ tokens: [Token]) throws {
        guard !tokens.isEmpty else { throw LLMError.tokenizationFailed }
        
        clearBatch()
        for (i, token) in tokens.enumerated() {
            addToBatchForEmbeddings(token: token, pos: Int32(i), isLogit: i == tokens.count - 1)
        }
        
        guard llama_decode(context, batch) == 0 else { throw LLMError.embeddingsFailed }
    }
    
    private func addToBatchForEmbeddings(token: Token, pos: Int32, isLogit: Bool = true) {
        let i = Int(batch.n_tokens)
        batch.token[i] = token
        batch.pos[i] = pos
        batch.n_seq_id[i] = 1
        if let seq_id = batch.seq_id[i] {
            seq_id[0] = 0
        }
        batch.logits[i] = isLogit ? 1 : 0
        batch.n_tokens += 1
    }
    
    private func extractEmbeddingsFromContext() throws -> [Float] {
        guard let embeddingsPtr = llama_get_embeddings_ith(context, -1) else {
            throw LLMError.embeddingsFailed
        }
        
        let embeddingDimension = Int(llama_model_n_embd(model))
        var embeddingsArray: [Float] = []
        embeddingsArray.reserveCapacity(embeddingDimension)
        
        for i in 0..<embeddingDimension {
            embeddingsArray.append(embeddingsPtr[i])
        }
        
        return embeddingsArray
    }
    
    public func getLastGeneratedTokens() -> [Token] {
        return debugLastGeneratedTokens
    }
    
    public func generateWithConstraints(from input: String, jsonSchema: String, thinking: ThinkingMode = .suppressed) throws -> String {
        debugLastGeneratedTokens = []
        guard prepareContext(for: input) else { throw LLMError.contextCreationFailed }
        
        guard let parsedSchema = parseJSONSchema(jsonSchema) else { throw LLMError.contextCreationFailed }
        if let sampler { llama_sampler_reset(sampler) }
        
        var output = ""
        
        try addToken("{", to: &output)
        
        guard let originalSchema = try JSONSerialization.jsonObject(with: jsonSchema.data(using: .utf8)!) as? [String: Any] else {
            throw LLMError.contextCreationFailed
        }
        
        for (index, field) in parsedSchema.fields.enumerated() {
            try addToken("\"\(field.name)\":", to: &output)
            
            try generateValueForField(field, into: &output, originalSchema: originalSchema, allowNull: !field.required)
            
            if index < parsedSchema.fields.count - 1 {
                try addToken(",", to: &output)
            }
        }
        try addToken("}", to: &output)
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func getValueStartTokensForField(_ field: SchemaField) -> Set<Token> {
        switch field.type {
        case .string:
            return Set([encode("\"", shouldAddBOS: false, special: false).first!])
        case .integer, .number:
            return Set("0123456789-".compactMap { encode(String($0), shouldAddBOS: false, special: false).first })
        case .boolean:
            let trueToken = encode("true", shouldAddBOS: false, special: false).first!
            let falseToken = encode("false", shouldAddBOS: false, special: false).first!
            return Set([trueToken, falseToken])
        case .array:
            return Set([encode("[", shouldAddBOS: false, special: false).first!])
        case .object:
            return Set([encode("{", shouldAddBOS: false, special: false).first!])
        }
    }
    
    private func generateValueForField(_ field: SchemaField, into output: inout String, originalSchema: [String: Any], allowNull: Bool = false) throws {
        if allowNull {
            let nullToken = encode("null", shouldAddBOS: false, special: false).first!
            let valueStartTokens = getValueStartTokensForField(field)
            let allowedTokens = valueStartTokens.union([nullToken])
            let decision = sampleNextToken(from: allowedTokens)
            
            if decision == nullToken {
                try addToken("null", to: &output)
                return
            }
        }
        
        switch field.type {
        case .string(let allowedValues):
            try generateStringValue(into: &output, allowedValues: allowedValues)
        case .integer:
            try generateIntegerValue(into: &output)
        case .number:
            try generateFloatingPointValue(into: &output)
        case .boolean:
            try generateBooleanValue(into: &output)
        case .array(let itemType):
            let fieldSchema = findFieldSchema(field.name, in: originalSchema)
            let itemSchema = fieldSchema?["items"] as? [String: Any]
            try generateArrayValue(into: &output, ofType: itemType, withItemSchema: itemSchema)
        case .object:
            let fieldSchema = findFieldSchema(field.name, in: originalSchema)
            try generateObjectValue(into: &output, with: fieldSchema)
        }
    }
    
    
    private func addToken(_ token: Token, to output: inout String) throws {
        if let sampler {
            llama_sampler_accept(sampler, token)
        }
        clearBatch()
        addToBatch(token: token, pos: currentTokenCount)
        guard llama_decode(context, batch) == 0 else {
            shouldContinuePredicting = false
            throw LLMError.decodingFailed
        }
        currentTokenCount += 1
        output += decode(token)
        debugLastGeneratedTokens.append(token)
    }
    
    private func addToken(_ string: String, to output: inout String) throws {
        let tokens = encode(string, shouldAddBOS: false, special: false)
        for token in tokens {
            try addToken(token, to: &output)
        }
    }

        
    private var _tokenSets: (stringTokens: Set<Token>, leadingWhitespaceTokens: Set<Token>)?
    private var tokenSets: (stringTokens: Set<Token>, leadingWhitespaceTokens: Set<Token>) {
        get {
            if let _tokenSets {
                return _tokenSets
            }

            var stringTokens: Set<Token> = []
            var leadingWhitespaceTokens: Set<Token> = []
            
            for i in 0..<totalTokenCount {
                let token = Token(i)
                let decoded = decode(token)
                if decoded.isEmpty || decoded.contains(where: {  !$0.isValidStringCharacter }) { continue }
                if let firstChar = decoded.first, firstChar.isWhitespace {
                    leadingWhitespaceTokens.insert(token)
                }
                if decoded.first?.isValidStringCharacter ?? false {
                    stringTokens.insert(token)
                }
            }
            
            let newSets = (stringTokens, leadingWhitespaceTokens)
            self._tokenSets = newSets
            return newSets
        }
    }
    
    private func generateStringValue(into output: inout String, allowedValues: [String]? = nil) throws {
        if let allowedValues, !allowedValues.isEmpty {
            try generateConstrainedString(into: &output, allowedValues: allowedValues)
            return
        }

        try addToken("\"", to: &output)
        
        let maxTokens = 128
        var tokensInString: [Token] = []
        var hasContent = false
        
        let (stringTokens, leadingWhitespaceTokens) = tokenSets
        
        
        while tokensInString.count < maxTokens {
            var allowedTokens = stringTokens
            if hasContent {
                allowedTokens.insert(quoteToken)
            }
            if !hasContent || output.last == " " {
                allowedTokens.subtract(leadingWhitespaceTokens)
            }
            
            let predictedToken = sampleNextToken(from: allowedTokens)
            guard predictedToken != endToken else { break }
            
            if predictedToken == quoteToken {
                break
            }
            
            try addToken(predictedToken, to: &output)
            let decoded = decode(predictedToken)
            tokensInString.append(predictedToken)
            
            if !hasContent && !decoded.trimmingCharacters(in: .whitespaces).isEmpty {
                hasContent = true
                allowedTokens.formUnion(leadingWhitespaceTokens)
            }
            
            if tokensInString.hasThreeSameElementsAtTheEnd {
                break
            }
        }
        try addToken("\"", to: &output)
    }
    
    private func generateConstrainedString(into output: inout String, allowedValues: [String]) throws {
        try addToken("\"", to: &output)
        
        var currentTokens: [Token] = []
        var candidateValues = allowedValues
        
        while !candidateValues.isEmpty {
            let possibleNextTokens = Set(candidateValues.flatMap { value in
                let fullTokens = encode(value, shouldAddBOS: false, special: false)
                return currentTokens.count < fullTokens.count ? [fullTokens[currentTokens.count]] : []
            })
            
            let quoteToken = encode("\"", shouldAddBOS: false, special: false).first!
            let allowedTokens = possibleNextTokens.union([quoteToken])
            
            let nextToken = sampleNextToken(from: allowedTokens)
            
            if nextToken == quoteToken {
                try addToken(nextToken, to: &output)
                return
            }
            
            currentTokens.append(nextToken)
            try addToken(nextToken, to: &output)
            
            candidateValues = candidateValues.filter { value in
                let valueTokens = encode(value, shouldAddBOS: false, special: false)
                return currentTokens.count <= valueTokens.count && 
                       Array(valueTokens.prefix(currentTokens.count)) == currentTokens
            }
        }
        
        try addToken("\"", to: &output)
    }
    
    private func generateIntegerValue(into output: inout String) throws {
        let maxLength = 19
        var generatedString = ""
        let digitTokens = Set("0123456789".compactMap { encode(String($0), shouldAddBOS: false, special: false).first })
        let minusToken = encode("-", shouldAddBOS: false, special: false).first!
        let commaToken = encode(",", shouldAddBOS: false, special: false).first!
        let closingBraceToken = encode("}", shouldAddBOS: false, special: false).first!
        let terminators = Set([commaToken, closingBraceToken])

        guard !digitTokens.isEmpty else { throw LLMError.tokenizationFailed }

        while generatedString.count < maxLength {
            var allowedTokens: Set<Token>

            if generatedString.isEmpty {
                allowedTokens = digitTokens.union([minusToken])
            } else if generatedString == "-" {
                allowedTokens = digitTokens
            } else if generatedString == "0" || generatedString == "-0" {
                allowedTokens = terminators
            } else {
                allowedTokens = digitTokens.union(terminators)
            }

            let nextToken = sampleNextToken(from: allowedTokens)
            guard nextToken != endToken else { break }

            if terminators.contains(nextToken) {
                break
            }

            try addToken(nextToken, to: &output)
            generatedString += decode(nextToken)
        }

        if generatedString.isEmpty || generatedString == "-" {
            let zeroToken = encode("0", shouldAddBOS: false, special: false).first!
            try addToken(zeroToken, to: &output)
        }
    }
    
    private func generateFloatingPointValue(into output: inout String) throws {
        let maxLength = 32
        var generatedString = ""
        let digitTokens = Set("0123456789".compactMap { encode(String($0), shouldAddBOS: false, special: false).first })
        let minusToken = encode("-", shouldAddBOS: false, special: false).first!
        let dotToken = encode(".", shouldAddBOS: false, special: false).first!
        let commaToken = encode(",", shouldAddBOS: false, special: false).first!
        let closingBraceToken = encode("}", shouldAddBOS: false, special: false).first!
        let terminators = Set([commaToken, closingBraceToken])

        guard !digitTokens.isEmpty else { throw LLMError.tokenizationFailed }

        while generatedString.count < maxLength {
            var allowedTokens: Set<Token>

            if generatedString.isEmpty {
                allowedTokens = digitTokens.union([minusToken])
            } else if generatedString == "-" {
                allowedTokens = digitTokens
            } else if generatedString == "0" || generatedString == "-0" {
                allowedTokens = terminators.union([dotToken])
            } else if generatedString.contains(".") {
                allowedTokens = digitTokens.union(terminators)
            } else {
                allowedTokens = digitTokens.union(terminators).union([dotToken])
            }

            let nextToken = sampleNextToken(from: allowedTokens)
            guard nextToken != endToken else { break }

            if terminators.contains(nextToken) {
                break
            }
            
            let decoded = decode(nextToken)
            if decoded == "." && generatedString.contains(".") { break }

            try addToken(nextToken, to: &output)
            generatedString += decoded
        }
        
        if generatedString.isEmpty || generatedString == "-" {
            let zeroToken = encode("0", shouldAddBOS: false, special: false).first!
            try addToken(zeroToken, to: &output)
        }

        if generatedString.last == "." {
            let zeroToken = encode("0", shouldAddBOS: false, special: false).first!
            try addToken(zeroToken, to: &output)
        }
    }
    
    private func generateBooleanValue(into output: inout String) throws {
        let trueToken = encode("true", shouldAddBOS: false, special: false).first!
        let falseToken = encode("false", shouldAddBOS: false, special: false).first!
        let allowedTokens = Set([trueToken, falseToken])
        
        let predictedToken = sampleNextToken(from: allowedTokens)
        guard predictedToken != endToken else {
            try addToken("false", to: &output)
            return
        }
        
        try addToken(predictedToken, to: &output)
    }
    
    private func generateObjectValue(into output: inout String, with schema: [String: Any]? = nil) throws {
        try addToken("{", to: &output)
        
        guard let schema = schema,
              let properties = schema["properties"] as? [String: Any],
              let required = schema["required"] as? [String] else {
            try addToken("}", to: &output)
            return
        }
        
        for (index, fieldName) in required.enumerated() {
            guard let fieldInfo = properties[fieldName] as? [String: Any] else { continue }
            
            try addToken("\"\(fieldName)\":", to: &output)
            try generateValueForFieldInfo(fieldInfo, into: &output)
            
            if index < required.count - 1 {
                try addToken(",", to: &output)
            }
        }
        
        try addToken("}", to: &output)
    }
    
    private func generateValueForFieldInfo(_ fieldInfo: [String: Any], into output: inout String) throws {
        if let enumValues = fieldInfo["enum"] as? [String] {
            try generateStringValue(into: &output, allowedValues: enumValues)
            return
        }
        
        let typeString = fieldInfo["type"] as? String ?? ""
        switch typeString {
        case "string":
            try generateStringValue(into: &output, allowedValues: nil)
        case "integer":
            try generateIntegerValue(into: &output)
        case "number":
            try generateFloatingPointValue(into: &output)
        case "boolean":
            try generateBooleanValue(into: &output)
        case "object":
            try generateObjectValue(into: &output, with: fieldInfo)
        case "array":
            if let items = fieldInfo["items"] as? [String: Any] {
                let itemType = parseItemType(from: items)
                try generateArrayValue(into: &output, ofType: itemType, withItemSchema: items)
            } else {
                try addToken("[]", to: &output)
            }
        default:
            try addToken("null", to: &output)
        }
    }
    
    private func parseItemType(from items: [String: Any]) -> JSONFieldType {
        if let enumValues = items["enum"] as? [String] {
            return .string(allowedValues: enumValues)
        }
        
        let itemTypeString = items["type"] as? String ?? ""
        switch itemTypeString {
        case "string": return .string(allowedValues: nil)
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "object": return .object
        default: return .string(allowedValues: nil)
        }
    }
    
    private func findFieldSchemaInOriginal(_ fieldName: String, originalSchema: String) -> [String: Any]? {
        guard let schemaData = originalSchema.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              let fieldSchema = properties[fieldName] as? [String: Any] else {
            return nil
        }
        return fieldSchema
    }
    
    private func findFieldSchema(_ fieldName: String, in originalSchema: [String: Any]) -> [String: Any]? {
        guard let properties = originalSchema["properties"] as? [String: Any],
              let fieldSchema = properties[fieldName] as? [String: Any] else {
            return nil
        }
        return fieldSchema
    }
    
    private func generateArrayValue(into output: inout String, ofType itemType: JSONFieldType, withItemSchema itemSchema: [String: Any]? = nil) throws {
        try addToken("[", to: &output)
        
        let maxItems = 5
        var itemCount = 0
        
        let closingBracketToken = encode("]", shouldAddBOS: false, special: false).first!
        let commaToken = encode(",", shouldAddBOS: false, special: false).first!
        
        while itemCount < maxItems {
            switch itemType {
            case .string(let allowedValues):
                try generateStringValue(into: &output, allowedValues: allowedValues)
            case .integer:
                try generateIntegerValue(into: &output)
            case .number:
                try generateFloatingPointValue(into: &output)
            case .boolean:
                try generateBooleanValue(into: &output)
            case .object:
                try generateObjectValue(into: &output, with: itemSchema)
            default:
                break
            }
            
            itemCount += 1
            
            if itemCount >= maxItems {
                break
            }
            
            let subsequentTokens = Set([commaToken, closingBracketToken])
            let nextToken = sampleNextToken(from: subsequentTokens)
            
            try addToken(nextToken, to: &output)
            
            if nextToken == closingBracketToken {
                return
            }
        }
        
        if !output.hasSuffix("]") {
            try addToken("]", to: &output)
        }
    }
    
    // MARK: - Schema-Driven JSON Generation
    
    private enum JSONFieldType: Equatable {
        case string(allowedValues: [String]?)
        case integer
        case number
        case boolean
        case object
        indirect case array(itemType: JSONFieldType)
    }
    
    private struct SchemaField: Equatable {
        let name: String
        let type: JSONFieldType
        let required: Bool
    }
    
    private struct ParsedSchema {
        let fields: [SchemaField]
        let requiredFields: [SchemaField]
    }
    
    private func parseJSONSchema(_ schemaString: String) -> ParsedSchema? {
        guard let schemaData = schemaString.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            return nil
        }
        
        let fieldNames = schema["ordered_keys"] as? [String] ?? properties.keys.sorted()
        
        let required = schema["required"] as? [String] ?? []
        var fields: [SchemaField] = []
        
        for fieldName in fieldNames {
            guard let fieldInfo = properties[fieldName] as? [String: Any] else { continue }
            
            let fieldType: JSONFieldType
            if let enumValues = fieldInfo["enum"] as? [String] {
                fieldType = .string(allowedValues: enumValues)
            } else {
                let typeString = fieldInfo["type"] as? String ?? ""
                switch typeString {
                case "string": fieldType = .string(allowedValues: nil)
                case "integer": fieldType = .integer
                case "number": fieldType = .number
                case "boolean": fieldType = .boolean
                case "object": fieldType = .object
                case "array":
                    guard let items = fieldInfo["items"] as? [String: Any],
                          let itemTypeString = items["type"] as? String else { continue }
                    switch itemTypeString {
                    case "string": 
                        if let enumValues = items["enum"] as? [String] {
                            fieldType = .array(itemType: .string(allowedValues: enumValues))
                        } else {
                            fieldType = .array(itemType: .string(allowedValues: nil))
                        }
                    case "integer": fieldType = .array(itemType: .integer)
                    case "number": fieldType = .array(itemType: .number)
                    case "object": fieldType = .array(itemType: .object)
                    case "boolean": fieldType = .array(itemType: .boolean)
                    default: continue
                    }
                default: continue
                }
            }
            
            let isRequired = required.contains(fieldName)
            fields.append(SchemaField(name: fieldName, type: fieldType, required: isRequired))
        }
        
        let requiredFields = fields.filter { $0.required }
        return ParsedSchema(fields: fields, requiredFields: requiredFields)
    }
    
    private func sampleNextToken(from allowedTokens: Set<Token>) -> Token {
        guard shouldContinuePredicting, currentTokenCount < Int32(maxTokenCount) else {
            return endToken
        }
        guard let sampler, !allowedTokens.isEmpty else { return endToken }
        let (_, leadingWhitespaceTokens) = tokenSets
        let protectedTokens = leadingWhitespaceTokens.union([quoteToken, endToken, whitespaceToken])
        var protectedLogits: [Token: Float] = [:]
        
        if let logits = llama_get_logits(context) {
            for token in protectedTokens {
                protectedLogits[token] = logits[Int(token)]
            }
            
            for t in 0..<totalTokenCount {
                let token = Token(t)
                if !allowedTokens.contains(token) {
                    logits[t] = -Float.infinity
                    if token != endToken {
                        protectedLogits.removeValue(forKey: token)
                    }
                }
            }
        }

        let i = batch.n_tokens - 1
        _ = llama_sampler_sample(sampler, context, i)
        
        if let logits = llama_get_logits(context) {
            for token in protectedTokens {
                if let logit = protectedLogits[token] {
                    logits[Int(token)] = logit
                }
            }
        }
        let token = llama_sampler_sample(sampler, context, i)
        return token
    }
    
    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            return false
        }
    }
    
    private func isComplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
    }
}

/// Errors that can occur during LLM operations.
public enum LLMError: Error {
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case decodingFailed
    case inputTooLong
    case decodeFailed
    case embeddingsFailed
}

/// A container for text embeddings generated by the model.
public struct Embeddings: Equatable {
    public let values: [Float]
    public let dimension: Int
    
    public init(values: [Float]) {
        self.values = values
        self.dimension = values.count
    }
    
    public func compare(with other: Embeddings) -> Double {
        guard dimension == other.dimension else { return 0.0 }
        
        let dotProduct = zip(values, other.values).reduce(0) { result, pair in result + pair.0 * pair.1 }
        let magnitudeA = sqrt(values.reduce(0) { $0 + $1 * $1 })
        let magnitudeB = sqrt(other.values.reduce(0) { $0 + $1 * $1 })
        
        guard magnitudeA > 0 && magnitudeB > 0 else { return 0.0 }
        
        let similarity = dotProduct / (magnitudeA * magnitudeB)
        return max(0, min(1, Double(similarity)))
    }
    
    public func findMostSimilar(in candidates: Embeddings...) -> Embeddings {
        guard !candidates.isEmpty else { return self }
        
        let similarities = candidates.map { compare(with: $0) }
        let maxIndex = similarities.enumerated().max { $0.element < $1.element }?.offset ?? 0
        
        return candidates[maxIndex]
    }
}

/// A wrapper for structured output generated according to a JSON schema.
///
/// This type ensures that the model's output conforms to the specified
/// structure defined by the `Generatable` protocol.
public struct StructuredOutput<T: Generatable> {
    public let value: T
    public let rawOutput: String
    
    public init(value: T, rawOutput: String) {
        self.value = value
        self.rawOutput = rawOutput
    }
}

/// Errors that can occur during structured output generation.
public enum StructuredOutputError: Error {
    case invalidJSON
    case schemaMismatch
    case decodingFailed
}

/// Main interface for interacting with Large Language Models in Swift applications.
///
/// `LLM` provides a high-level, SwiftUI-compatible interface for running language models
/// locally using llama.cpp. It manages conversation history, provides async/await methods
/// for generation, and integrates seamlessly with SwiftUI through `ObservableObject`.
///
/// ## Usage
///
/// ```swift
/// let llm = try await LLM(from: .bundle(resource: "model", extension: "gguf"))
/// let response = try await llm.generate(from: "Hello, how are you?")
/// ```
///
/// ## Features
///
/// - **Conversation Management**: Automatically maintains chat history
/// - **SwiftUI Integration**: Works as an `ObservableObject` for reactive UI updates
/// - **Async/Await Support**: Modern Swift concurrency for non-blocking operations
/// - **Streaming Responses**: Real-time token generation via `AsyncStream`
/// - **Template Support**: Built-in chat templates for popular model formats
/// - **Structured Output**: Generate JSON conforming to specified schemas
open class LLM: ObservableObject {
    private(set) var model: Model
    public var history: [Chat]
    public var preprocess: @Sendable (_ input: String, _ history: [Chat], _ thinking: ThinkingMode) -> String = { input, _, _ in return input }
    public var postprocess: @Sendable (_ output: String) -> Void = { print($0) }
    public var update: @Sendable (_ outputDelta: String?) -> Void = { _ in }
    public var updateThinking: @Sendable (_ thinkingDelta: String?) -> Void = { _ in }
    
    @Published public private(set) var output = ""
    @Published public private(set) var thinking = ""
    
    public var template: Template? = nil {
        didSet {
            guard let template else {
                preprocess = { input, _, _ in return input }
                Task {
                    await core.setStopSequence(nil)
                    await core.setThinkingTokens(start: nil, end: nil, startMarker: nil, endMarker: nil)
                }
                return
            }
            preprocess = template.preprocess
            Task {
                await core.setStopSequence(template.stopSequence)
                await setupThinkingTokens(from: template)
            }
        }
    }
    
    public var seed: UInt32 {
        didSet {
            Task { await core.setParameters(seed: seed) }
        }
    }
    
    public var topK: Int32 {
        didSet {
            Task { await core.setParameters(topK: topK) }
        }
    }
    
    public var topP: Float {
        didSet {
            Task { await core.setParameters(topP: topP) }
        }
    }
    
    public var temp: Float {
        didSet {
            Task { await core.setParameters(temp: temp) }
        }
    }

    public var repeatPenalty: Float {
        didSet {
            Task { await core.setParameters(repeatPenalty: repeatPenalty) }
        }
    }
    
    public var repetitionLookback: Int32 {
        didSet {
            Task { await core.setParameters(repetitionLookback: repetitionLookback) }
        }
    }
    
    public var historyLimit: Int
    public var path: [CChar]
    
    public let core: LLMCore
    
    private var isAvailable = true
    private var input: String = ""
    
    static var isLogSilenced = false

    private enum BackendLifecycle {
        static let lock = NSLock()
        static var isInitialized = false
        static var initialize: () -> Void = {
            llama_backend_init()
        }
        static var shutdown: () -> Void = {
            llama_backend_free()
        }
    }

    fileprivate static func ensureInitialized() {
        BackendLifecycle.lock.lock()
        defer { BackendLifecycle.lock.unlock() }

        guard !BackendLifecycle.isInitialized else { return }
        BackendLifecycle.initialize()
        BackendLifecycle.isInitialized = true
    }

    public static func shutdownBackend() {
        BackendLifecycle.lock.lock()
        defer { BackendLifecycle.lock.unlock() }

        guard BackendLifecycle.isInitialized else { return }
        BackendLifecycle.shutdown()
        BackendLifecycle.isInitialized = false
    }

    static func setBackendHooksForTesting(
        initialize: @escaping () -> Void,
        shutdown: @escaping () -> Void,
        isInitialized: Bool = false
    ) {
        BackendLifecycle.lock.lock()
        defer { BackendLifecycle.lock.unlock() }

        BackendLifecycle.initialize = initialize
        BackendLifecycle.shutdown = shutdown
        BackendLifecycle.isInitialized = isInitialized
    }

    static func resetBackendHooksForTesting() {
        BackendLifecycle.lock.lock()
        defer { BackendLifecycle.lock.unlock() }

        BackendLifecycle.initialize = {
            llama_backend_init()
        }
        BackendLifecycle.shutdown = {
            llama_backend_free()
        }
        BackendLifecycle.isInitialized = false
    }

    static func silenceLogging() {
        guard !isLogSilenced else { return }
        isLogSilenced = true
        let noopCallback: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, _ in }
        llama_log_set(noopCallback, nil)
        ggml_log_set(noopCallback, nil)
    }
    
    
    public init?(
        from path: String,
        stopSequence: String? = nil,
        history: [Chat] = [],
        seed: UInt32 = .random(in: .min ... .max),
        topK: Int32 = 40,
        topP: Float = 0.95,
        temp: Float = 0.8,
        repeatPenalty: Float = 1.2,
        repetitionLookback: Int32 = 64,
        historyLimit: Int = 8,
        maxTokenCount: Int32 = 2048
    ) {
        LLM.silenceLogging()
        self.path = path.cString(using: .utf8)!
        self.seed = seed
        self.topK = topK
        self.topP = topP
        self.temp = temp
        self.historyLimit = historyLimit
        self.history = history
        self.repeatPenalty = repeatPenalty
        self.repetitionLookback = repetitionLookback
        
        #if DEBUG
        print("GNERATING WITH SEEED: \(seed)")
        #endif
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #endif
        guard let model = llama_model_load_from_file(self.path, modelParams) else {
            return nil
        }
        self.model = model
        
        let finalMaxTokenCount = Int(min(maxTokenCount, llama_model_n_ctx_train(model)))
        
        do {
            self.core = try LLMCore(
                model: model,
                path: self.path,
                seed: seed,
                topK: topK,
                topP: topP,
                temp: temp,
                repeatPenalty: repeatPenalty,
                repetitionLookback: repetitionLookback,
                maxTokenCount: finalMaxTokenCount
            )
            
            if let stopSequence {
                Task {
                    await core.setStopSequence(stopSequence)
                }
            }
        } catch {
            llama_model_free(model)
            return nil
        }
    }
    
    public convenience init?(
        from url: URL,
        stopSequence: String? = nil,
        history: [Chat] = [],
        seed: UInt32 = .random(in: .min ... .max),
        topK: Int32 = 40,
        topP: Float = 0.95,
        temp: Float = 0.8,
        repeatPenalty: Float = 1.2,
        repetitionLookback: Int32 = 64,
        historyLimit: Int = 8,
        maxTokenCount: Int32 = 2048
    ) {
        self.init(
            from: url.path,
            stopSequence: stopSequence,
            history: history,
            seed: seed,
            topK: topK,
            topP: topP,
            temp: temp,
            repeatPenalty: repeatPenalty,
            repetitionLookback: repetitionLookback,
            historyLimit: historyLimit,
            maxTokenCount: maxTokenCount
        )
    }
    
    public convenience init?(
        from url: URL,
        template: Template,
        history: [Chat] = [],
        seed: UInt32 = .random(in: .min ... .max),
        topK: Int32 = 40,
        topP: Float = 0.95,
        temp: Float = 0.8,
        repeatPenalty: Float = 1.2,
        repetitionLookback: Int32 = 64,
        historyLimit: Int = 8,
        maxTokenCount: Int32 = 2048
    ) {
        self.init(
            from: url.path,
            stopSequence: template.stopSequence,
            history: history,
            seed: seed,
            topK: topK,
            topP: topP,
            temp: temp,
            repeatPenalty: repeatPenalty,
            repetitionLookback: repetitionLookback,
            historyLimit: historyLimit,
            maxTokenCount: maxTokenCount
        )
        self.preprocess = template.preprocess
        self.template = template
    }

    public func resolvedTemplate(
        systemPrompt: String? = nil,
        overriding explicitTemplate: Template? = nil,
        modelName: String? = nil
    ) -> Template {
        TemplateResolver.resolve(
            systemPrompt: systemPrompt,
            explicitTemplate: explicitTemplate,
            context: templateResolutionContext(modelName: modelName)
        )
    }

    public func useResolvedTemplate(
        systemPrompt: String? = nil,
        overriding explicitTemplate: Template? = nil,
        modelName: String? = nil
    ) {
        template = resolvedTemplate(
            systemPrompt: systemPrompt,
            overriding: explicitTemplate,
            modelName: modelName
        )
    }
    
    public convenience init?(
        from huggingFaceModel: HuggingFaceModel,
        to url: URL = .documentsDirectory,
        as name: String? = nil,
        history: [Chat] = [],
        seed: UInt32 = .random(in: .min ... .max),
        topK: Int32 = 40,
        topP: Float = 0.95,
        temp: Float = 0.8,
        repeatPenalty: Float = 1.2,
        repetitionLookback: Int32 = 64,
        historyLimit: Int = 8,
        maxTokenCount: Int32 = 2048,
        updateProgress: @Sendable @escaping (Double) -> Void = { print(String(format: "downloaded(%.2f%%)", $0 * 100)) }
    ) async throws {
        let url = try await huggingFaceModel.download(to: url, as: name) { progress in
            Task { @MainActor in updateProgress(progress) }
        }
        let template = huggingFaceModel.resolveTemplate()
        self.init(
            from: url,
            template: template,
            history: history,
            seed: seed,
            topK: topK,
            topP: topP,
            temp: temp,
            repeatPenalty: repeatPenalty,
            repetitionLookback: repetitionLookback,
            historyLimit: historyLimit,
            maxTokenCount: maxTokenCount
        )
        await setupThinkingTokens(from: template)
    }
    
    private func setupThinkingTokens(from template: Template?) async {
        guard let template else { return }
        let (startTokens, startMarker) = await convertToTokensAndMarker(template.thinkingStart)
        let (endTokens, endMarker) = await convertToTokensAndMarker(template.thinkingEnd)
        await core.setThinkingTokens(start: startTokens, end: endTokens, startMarker: startMarker, endMarker: endMarker)
    }
    
    private func convertToTokensAndMarker(_ sequence: TokenSequence?) async -> ([Token]?, String?) {
        guard let sequence else { return (nil, nil) }
        switch sequence {
        case .string(let text):
            return (await core.encode(text, shouldAddBOS: false, special: false), text)
        case .token(let token):
            return ([token], await core.decode(token, special: true))
        }
    }

    private func templateResolutionContext(modelName: String? = nil) -> TemplateResolutionContext {
        let currentPath = String(cString: path)
        return TemplateResolutionContext(
            modelName: modelName,
            fileName: URL(fileURLWithPath: currentPath).lastPathComponent,
            metadata: [
                "general.architecture": modelMetadataValue(for: "general.architecture"),
                "general.name": modelMetadataValue(for: "general.name")
            ].compactMapValues { $0 },
            chatTemplateHint: nil
        )
    }

    private func modelMetadataValue(for key: String) -> String? {
        var bufferSize = 256

        while true {
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let written = key.withCString { keyPointer in
                llama_model_meta_val_str(model, keyPointer, &buffer, buffer.count)
            }

            if written < 0 {
                return nil
            }
            if written < buffer.count {
                return String(cString: buffer)
            }

            bufferSize = Int(written) + 1
        }
    }
    
    @MainActor public func setOutput(to newOutput: consuming String) {
        output = newOutput
    }
    
    @MainActor public func setThinking(to newThinking: consuming String) {
        thinking = newThinking
    }
    
    public func stop() {
        Task { await core.stopGeneration() }
    }
    
    public func reset() {
        history.removeAll()
        Task { await core.resetContext() }
    }

    private func resetContextIfHistoryIsEmpty() async {
        guard history.isEmpty else { return }
        await core.resetContext()
    }
    
    open func recoverFromLengthy(_ input: borrowing String, to output: borrowing AsyncStream<String>.Continuation) {
        output.yield("TL;DR")
    }
    
    public func getCompletion(from input: borrowing String, maxNewTokens: Int? = nil) async -> String {
        guard isAvailable else { return "LLM is being used" }
        
        isAvailable = false
        defer { isAvailable = true }

        await resetContextIfHistoryIsEmpty()
        
        let response = await core.generateResponseStream(from: input, maxNewTokens: maxNewTokens)
        var output = ""
        
        for await content in response {
            output += content
        }
        
        return output
    }
    
    public func respond(to input: String, thinking: ThinkingMode = .none, with makeOutputFrom: @escaping (AsyncStream<String>) async -> String) async {
        guard isAvailable else { return }
        
        isAvailable = false
        defer { isAvailable = true }

        await resetContextIfHistoryIsEmpty()
        
        self.input = input
        let processedInput = preprocess(input, history, thinking)
        
        let response = await core.generateResponseStream(from: processedInput, thinking: thinking)
        let output = await makeOutputFrom(response)
        
        history += [(.user, input), (.bot, output)]
        let historyCount = history.count
        if historyLimit < historyCount {
            history.removeFirst(min(2, historyCount))
        }
        
        postprocess(output)
    }
    
    open func respond(to input: String, thinking: ThinkingMode = .none) async {
        guard isAvailable else { return }
        
        isAvailable = false
        defer { isAvailable = true }

        await resetContextIfHistoryIsEmpty()
        
        self.input = input
        let processedInput = preprocess(input, history, thinking)
        
        let (thinkingStream, responseStream) = await core.generateResponseStreamWithThinking(from: processedInput, thinking: thinking)
        
        await setOutput(to: "")
        await setThinking(to: "")
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await content in thinkingStream {
                    self.updateThinking(content)
                    await self.setThinking(to: self.thinking + content)
                }
                self.updateThinking(nil)
            }
            
            group.addTask {
                for await content in responseStream {
                    self.update(content)
                    await self.setOutput(to: self.output + content)
                }
                self.update(nil)
            }
        }
        
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        await setOutput(to: trimmedOutput.isEmpty ? "..." : trimmedOutput)
        
        history += [(.user, input), (.bot, output)]
        let historyCount = history.count
        if historyLimit < historyCount {
            history.removeFirst(min(2, historyCount))
        }
        
        postprocess(output)
    }
    
    public func encode(_ text: borrowing String, shouldAddBOS: Bool = true) async -> [Token] {
        return await core.encode(text, shouldAddBOS: shouldAddBOS)
    }
    
    public func getEmbeddings(_ text: String) async throws -> Embeddings {
        let values = try await core.getEmbeddings(from: text)
        return Embeddings(values: values)
    }
    
    public func respond<T: Generatable>(
        to prompt: String,
        as type: T.Type,
        thinking: ThinkingMode = .none
    ) async throws -> StructuredOutput<T> {
        await resetContextIfHistoryIsEmpty()

        let schemaPrompt = """
        \(prompt)
        
        Generate a JSON response that:
        Matches this exact schema: \(T.jsonSchema)
        Return only the JSON object, no other text.
        """
        let processedPrompt = preprocess(schemaPrompt, history, thinking)
        
        let rawOutput = try await core.generateWithConstraints(
            from: processedPrompt,
            jsonSchema: T.jsonSchema,
            thinking: thinking
        )
        
        guard let jsonData = rawOutput.data(using: .utf8) else {
            throw StructuredOutputError.invalidJSON
        }
        
        do {
            let decodedValue = try JSONDecoder().decode(T.self, from: jsonData)
            let output = StructuredOutput(value: decodedValue, rawOutput: rawOutput)
            history += [(.user, processedPrompt), (.bot, rawOutput)]
            let historyCount = history.count
            if historyLimit < historyCount {
                history.removeFirst(min(2, historyCount))
            }
            postprocess(rawOutput)
            return output
        } catch {
            print("JSON Decoding failed:")
            print("Raw output: '\(rawOutput)'")
            print("JSON data: '\(String(data: jsonData, encoding: .utf8) ?? "nil")'")
            print("Error: \(error)")
            print("Schema: \(T.jsonSchema)")
            throw StructuredOutputError.decodingFailed
        }
    }
}

/// The role of a participant in a chat conversation.
public enum Role {
    case user
    case bot
}

/// A sequence of tokens that can be represented as either a string or a single token ID.
public enum TokenSequence: Sendable, Equatable {
    case string(String)
    case token(Token)
    
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension TokenSequence: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension TokenSequence: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int32) {
        self = .token(value)
    }
}

enum TemplateFamily: Sendable, Equatable {
    case chatML
    case qwen
    case alpaca
    case llama
    case mistral
    case gemma

    func makeTemplate(systemPrompt: String?) -> Template {
        switch self {
        case .chatML:
            return .chatML(systemPrompt)
        case .qwen:
            return .qwen(systemPrompt)
        case .alpaca:
            return .alpaca(systemPrompt)
        case .llama:
            return .llama(systemPrompt)
        case .mistral:
            return .mistral
        case .gemma:
            return .gemma
        }
    }
}

struct TemplateResolutionContext: Sendable {
    var modelName: String?
    var fileName: String?
    var metadata: [String: String] = [:]
    var chatTemplateHint: String?
}

enum TemplateResolver {
    static func resolve(
        systemPrompt: String? = nil,
        explicitTemplate: Template? = nil,
        context: TemplateResolutionContext
    ) -> Template {
        if let explicitTemplate {
            return explicitTemplate
        }

        let family = inferFamily(from: context) ?? .chatML
        return family.makeTemplate(systemPrompt: systemPrompt)
    }

    static func inferFamily(from context: TemplateResolutionContext) -> TemplateFamily? {
        if let family = inferFamily(fromChatTemplateHint: context.chatTemplateHint) {
            return family
        }

        for key in ["general.architecture", "general.name"] {
            if let value = context.metadata[key], let family = inferFamily(fromIdentifier: value) {
                return family
            }
        }

        for value in context.metadata.values {
            if let family = inferFamily(fromIdentifier: value) {
                return family
            }
        }

        for identifier in [context.modelName, context.fileName] {
            if let identifier, let family = inferFamily(fromIdentifier: identifier) {
                return family
            }
        }

        return nil
    }

    private static func inferFamily(fromChatTemplateHint hint: String?) -> TemplateFamily? {
        guard let loweredHint = hint?.lowercased(), !loweredHint.isEmpty else { return nil }

        if loweredHint.contains("enable_thinking") || loweredHint.contains("<think>\n") || loweredHint.contains("qwen") {
            return .qwen
        }
        if loweredHint.contains("<start_of_turn>") {
            return .gemma
        }
        if loweredHint.contains("[inst]") && loweredHint.contains("<<sys>>") {
            return .llama
        }
        if loweredHint.contains("[inst]") {
            return .mistral
        }
        if loweredHint.contains("### instruction:") {
            return .alpaca
        }
        if loweredHint.contains("<|im_start|>") {
            return .chatML
        }

        return inferFamily(fromIdentifier: loweredHint)
    }

    private static func inferFamily(fromIdentifier identifier: String) -> TemplateFamily? {
        let loweredIdentifier = identifier.lowercased()

        if loweredIdentifier.contains("qwen") {
            return .qwen
        }
        if loweredIdentifier.contains("gemma") {
            return .gemma
        }
        if loweredIdentifier.contains("mistral") {
            return .mistral
        }
        if loweredIdentifier.contains("alpaca") {
            return .alpaca
        }
        if loweredIdentifier.contains("tinyllama") || loweredIdentifier.contains("llama") {
            return .llama
        }
        if loweredIdentifier.contains("chatml") {
            return .chatML
        }

        return nil
    }
}

/// A chat template for formatting conversations according to model-specific formats.
///
/// Templates handle the preprocessing of user input and conversation history
/// into formats expected by different language models, including system prompts,
/// message formatting, and stop sequences.
public struct Template: Sendable {
    public typealias Attachment = (prefix: String, suffix: String)
    public let system: Attachment
    public let user: Attachment
    public let bot: Attachment
    public let systemPrompt: String?
    public let stopSequence: String?
    public let thinkingStart: TokenSequence?
    public let thinkingEnd: TokenSequence?
    public let prefix: String
    public let shouldDropLast: Bool
    
    public init(
        prefix: String = "",
        system: Attachment? = nil,
        user: Attachment? = nil,
        bot: Attachment? = nil,
        stopSequence: String? = nil,
        thinkingStart: TokenSequence? = nil,
        thinkingEnd: TokenSequence? = nil,
        systemPrompt: String?,
        shouldDropLast: Bool = false
    ) {
        self.system = system ?? ("", "")
        self.user = user  ?? ("", "")
        self.bot = bot ?? ("", "")
        self.stopSequence = stopSequence
        self.thinkingStart = thinkingStart
        self.thinkingEnd = thinkingEnd
        self.systemPrompt = systemPrompt
        self.prefix = prefix
        self.shouldDropLast = shouldDropLast
    }
    
    public var preprocess: @Sendable (_ input: String, _ history: [Chat], _ thinking: ThinkingMode) -> String {
        return { [self] input, history, thinking in
            var processed = prefix
            if let systemPrompt {
                processed += "\(system.prefix)\(systemPrompt)\(system.suffix)"
            }
            for chat in history {
                if chat.role == .user {
                    processed += "\(user.prefix)\(chat.content)\(user.suffix)"
                } else {
                    processed += "\(bot.prefix)\(chat.content)\(bot.suffix)"
                }
            }
            processed += "\(user.prefix)\(input)\(user.suffix)"
            if shouldDropLast {
                processed += bot.prefix.dropLast()
            } else {
                processed += bot.prefix
            }
            
            if thinking == .enabled, let start = thinkingStart?.stringValue {
                processed += start
            } else if thinking == .suppressed, let start = thinkingStart?.stringValue, let end = thinkingEnd?.stringValue {
                processed += start + end
            }
            
            return processed
        }
    }
    
    public static func chatML(_ systemPrompt: String? = nil) -> Template {
        return Template(
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequence: "<|im_end|>",
            thinkingStart: "<think>",
            thinkingEnd: "</think>",
            systemPrompt: systemPrompt
        )
    }

    public static func qwen(_ systemPrompt: String? = nil) -> Template {
        return Template(
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequence: "<|im_end|>",
            thinkingStart: "<think>\n",
            thinkingEnd: "\n</think>\n\n",
            systemPrompt: systemPrompt
        )
    }
    
    public static func alpaca(_ systemPrompt: String? = nil) -> Template {
        return Template(
            system: ("", "\n\n"),
            user: ("### Instruction:\n", "\n\n"),
            bot: ("### Response:\n", "\n\n"),
            stopSequence: "###",
            systemPrompt: systemPrompt
        )
    }
    
    public static func llama(_ systemPrompt: String? = nil) -> Template {
        return Template(
            prefix: "[INST] ",
            system: ("<<SYS>>\n", "\n<</SYS>>\n\n"),
            user: ("", " [/INST]"),
            bot: (" ", "</s><s>[INST] "),
            stopSequence: "</s>",
            thinkingStart: "[THINK]",
            thinkingEnd: "[/THINK]",
            systemPrompt: systemPrompt,
            shouldDropLast: true
        )
    }
    
    public static let mistral = Template(
        user: ("[INST] ", " [/INST]"),
        bot: ("", "</s> "),
        stopSequence: "</s>",
        thinkingStart: "[THINK]",
        thinkingEnd: "[/THINK]",
        systemPrompt: nil
    )
    
    public static let gemma = Template(
        user: ("<start_of_turn>user\n", "<end_of_turn>\n"),
        bot: ("<start_of_turn>model\n", "<end_of_turn>\n"),
        stopSequence: "<end_of_turn>",
        thinkingStart: "<think>",
        thinkingEnd: "</think>",
        systemPrompt: nil
    )
}

/// Quantization levels available for model compression.
///
/// Quantization reduces model size and memory usage at the cost of some accuracy.
public enum Quantization: String {
    case IQ1_S
    case IQ1_M
    case IQ2_XXS
    case IQ2_XS
    case IQ2_S
    case IQ2_M
    case Q2_K_S
    case Q2_K
    case IQ3_XXS
    case IQ3_XS
    case IQ3_S
    case IQ3_M
    case Q3_K_S
    case Q3_K_M
    case Q3_K_L
    case IQ4_XS
    case IQ4_NL
    case Q4_0
    case Q4_1
    case Q4_K_S
    case Q4_K_M
    case Q5_0
    case Q5_1
    case Q5_K_S
    case Q5_K_M
    case Q6_K
    case Q8_0
}

/// Errors that can occur when downloading models from Hugging Face.
public enum HuggingFaceError: Error {
    case network(statusCode: Int)
    case noFilteredURL
    case urlIsNilForSomeReason
}

/// A utility for downloading and managing models from Hugging Face.
///
/// This struct provides methods to download GGUF models directly from
/// Hugging Face repositories with support for different quantization levels.
public struct HuggingFaceModel {
    public let name: String
    public let template: Template?
    public let filterRegexPattern: String
    
    public init(_ name: String, template: Template? = nil, filterRegexPattern: String) {
        self.name = name
        self.template = template
        self.filterRegexPattern = filterRegexPattern
    }
    
    public init(_ name: String, _ quantization: Quantization? = .Q4_K_M, template: Template? = nil) {
        self.name = name
        self.template = template
        self.filterRegexPattern = quantization.map { "(?i)\($0.rawValue)" } ?? ".*"
    }

    public func resolveTemplate(systemPrompt: String? = nil, overriding explicitTemplate: Template? = nil) -> Template {
        TemplateResolver.resolve(
            systemPrompt: systemPrompt,
            explicitTemplate: explicitTemplate ?? template,
            context: TemplateResolutionContext(modelName: name)
        )
    }
    
    package func getDownloadURLStrings() async throws -> [String] {
        let url = URL(string: "https://huggingface.co/\(name)/tree/main")!
        let data = try await url.getData()
        let content = String(data: data, encoding: .utf8)!
        let downloadURLPattern = #"(?<=href=").*\.gguf\?download=true"#
        let matches = try! downloadURLPattern.matches(in: content)
        let root = "https://huggingface.co"
        return matches.map { match in root + match }
    }
    
    package func getDownloadURL() async throws -> URL? {
        let urlStrings = try await getDownloadURLStrings()
        for urlString in urlStrings {
            let found = try filterRegexPattern.hasMatch(in: urlString)
            if found { return URL(string: urlString)! }
        }
        return nil
    }
    
    public func download(to directory: URL = .documentsDirectory, as name: String? = nil, _ updateProgress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        var destination: URL
        if let name {
            destination = directory.appending(path: name)
            guard !destination.exists else { updateProgress(1); return destination }
        }
        guard let downloadURL = try await getDownloadURL() else { throw HuggingFaceError.noFilteredURL }
        destination = directory.appending(path: downloadURL.lastPathComponent)
        guard !destination.exists else { return destination }
        try await downloadURL.downloadData(to: destination, updateProgress)
        return destination
    }
    
    public static func tinyLLaMA(_ quantization: Quantization = .Q4_K_M, _ systemPrompt: String) -> HuggingFaceModel {
        HuggingFaceModel("TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF", quantization, template: .chatML(systemPrompt))
    }
}

extension URL {
    @backDeployed(before: iOS 16)
    public func appending(path: String) -> URL {
        appendingPathComponent(path)
    }
    @backDeployed(before: iOS 16)
    public static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    fileprivate var exists: Bool { FileManager.default.fileExists(atPath: path) }
    fileprivate func getData() async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: self)
        let statusCode = (response as! HTTPURLResponse).statusCode
        guard statusCode / 100 == 2 else { throw HuggingFaceError.network(statusCode: statusCode) }
        return data
    }
    fileprivate func downloadData(to destination: URL, _ updateProgress: @Sendable @escaping (Double) -> Void) async throws {
        var observation: NSKeyValueObservation!
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: self) { url, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let url else { return continuation.resume(throwing: HuggingFaceError.urlIsNilForSomeReason) }
                let statusCode = (response as! HTTPURLResponse).statusCode
                guard statusCode / 100 == 2 else { return continuation.resume(throwing: HuggingFaceError.network(statusCode: statusCode)) }
                continuation.resume(returning: url)
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                updateProgress(progress.fractionCompleted)
            }
            task.resume()
        }
        _ = observation
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

package extension String {
    func matches(in content: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: self)
        let range = NSRange(location: 0, length: content.utf16.count)
        let matches = pattern.matches(in: content, range: range)
        return matches.map { match in String(content[Range(match.range, in: content)!]) }
    }
    func hasMatch(in content: String) throws -> Bool {
        let pattern = try NSRegularExpression(pattern: self)
        let range = NSRange(location: 0, length: content.utf16.count)
        return pattern.firstMatch(in: content, range: range) != nil
    }
    func firstMatch(in content: String) throws -> String? {
        let pattern = try NSRegularExpression(pattern: self)
        let range = NSRange(location: 0, length: content.utf16.count)
        guard let match = pattern.firstMatch(in: content, range: range) else { return nil }
        return String(content[Range(match.range, in: content)!])
    }
}

extension [String] {
    mutating func scoup(_ count: Int) {
        guard 0 < count else { return }
        let firstIndex = count
        let lastIndex = count * 2
        self.removeSubrange(firstIndex..<lastIndex)
    }
}

extension Array where Element: Equatable {
    var hasThreeSameElementsAtTheEnd: Bool {
        count >= 3 && self[count - 3] == self[count - 2] && self[count - 2] == self[count - 1]
    }
}

extension Character {
    var isValidStringCharacter: Bool {
        guard self != "\"" && self != "\\" else { return false }
        return isLetter || self == " " || isNumber || isLowercase || isUppercase || isASCII && isPunctuation || isASCII && isSymbol
    }
}
