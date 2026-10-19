//
//  LlamaContext.swift
//  OpenSuperWhisper
//
//  Swift wrapper over the llama.cpp C API (pinned tag b9878, 2026-07-05), mirroring
//  the structure of Whis/Whis.swift. Holds OpaquePointers for the llama_model and
//  llama_context and exposes a minimal text-generation API used by the built-in LLM
//  cleanup backend.
//
//  This file is written against the signatures declared in
//  libwhisper/llama.cpp/include/llama.h at tag b9878. The relevant declarations:
//
//    void                  llama_backend_init(void);
//    void                  llama_backend_free(void);
//    llama_model_params    llama_model_default_params(void);
//    llama_context_params  llama_context_default_params(void);
//    llama_model *         llama_model_load_from_file(const char * path_model,
//                                                     llama_model_params params);
//    void                  llama_model_free(llama_model * model);
//    llama_context *       llama_init_from_model(llama_model * model,
//                                                llama_context_params params);
//    void                  llama_free(llama_context * ctx);
//    const llama_vocab *   llama_model_get_vocab(const llama_model * model);
//    int32_t               llama_vocab_n_tokens(const llama_vocab * vocab);
//    bool                  llama_vocab_is_eog(const llama_vocab * vocab, llama_token token);
//    const char *          llama_model_chat_template(const llama_model * model, const char * name);
//    int32_t               llama_chat_apply_template(const char * tmpl,
//                                                    const llama_chat_message * chat,
//                                                    size_t n_msg, bool add_ass,
//                                                    char * buf, int32_t length);
//    int32_t               llama_tokenize(const llama_vocab * vocab, const char * text,
//                                         int32_t text_len, llama_token * tokens,
//                                         int32_t n_tokens_max, bool add_special,
//                                         bool parse_special);
//    int32_t               llama_token_to_piece(const llama_vocab * vocab, llama_token token,
//                                               char * buf, int32_t length, int32_t lstrip,
//                                               bool special);
//    llama_batch           llama_batch_get_one(llama_token * tokens, int32_t n_tokens);
//    int32_t               llama_decode(llama_context * ctx, llama_batch batch);
//    uint32_t              llama_n_ctx(const llama_context * ctx);
//    llama_memory_t        llama_get_memory(const llama_context * ctx);
//    void                  llama_memory_clear(llama_memory_t mem, bool data);
//    llama_pos             llama_memory_seq_pos_max(llama_memory_t mem, llama_seq_id seq_id);
//    bool                  llama_memory_seq_rm(llama_memory_t mem, llama_seq_id seq_id,
//                                              llama_pos p0, llama_pos p1);
//    void                  llama_memory_seq_cp(llama_memory_t mem, llama_seq_id seq_id_src,
//                                              llama_seq_id seq_id_dst, llama_pos p0, llama_pos p1);
//    void                  llama_sampler_reset(llama_sampler * smpl);
//    llama_sampler_chain_params llama_sampler_chain_default_params(void);
//    llama_sampler *       llama_sampler_chain_init(llama_sampler_chain_params params);
//    void                  llama_sampler_chain_add(llama_sampler * chain, llama_sampler * smpl);
//    llama_sampler *       llama_sampler_init_greedy(void);
//    llama_sampler *       llama_sampler_init_temp(float t);
//    llama_sampler *       llama_sampler_init_top_k(int32_t k);
//    llama_sampler *       llama_sampler_init_top_p(float p, size_t min_keep);
//    llama_sampler *       llama_sampler_init_dist(uint32_t seed);
//    llama_token           llama_sampler_sample(llama_sampler * smpl, llama_context * ctx, int32_t idx);
//    void                  llama_sampler_accept(llama_sampler * smpl, llama_token token);
//    void                  llama_sampler_free(llama_sampler * smpl);
//
//  struct llama_chat_message { const char * role; const char * content; }
//
//  NOTE: the signatures above are copied verbatim from the pinned header; if the
//  submodule is bumped, re-verify them.
//

import Foundation
internal import OSWNative

/// NOT thread-safe: `llama_context` holds the KV cache and must be used by one caller at a
/// time. Every access goes through `BuiltInLlamaBackend`'s serial inference queue, which is
/// also what owns this object's lifetime.
final class LlamaContext {

    typealias LlamaToken = Int32

    // llama_model* and llama_context* are opaque in llama.h, so they import as OpaquePointer.
    // llama_sampler is a complete struct, so it imports as UnsafeMutablePointer<llama_sampler>.
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private let vocab: OpaquePointer?

    /// Whether the model's chat template has a thinking mode, which `generate` switches off.
    let supportsThinking: Bool

    /// Generation runs in sequence 0. Sequence 1 holds the decoded system-prompt prefix.
    private static let generationSequence: llama_seq_id = 0
    private static let prefixSequence: llama_seq_id = 1

    /// Tokens of the system-prompt prefix that sequence 1 holds decoded. A hybrid model such as
    /// Qwen3.5 has recurrent layers that cannot drop the tail of a sequence (`llama_memory_seq_rm`
    /// fails on a partial range), so the prefix lives in its own sequence and each prompt starts
    /// from a copy of the whole of it.
    private var keptPrefix: [LlamaToken]?

    /// How many prompt tokens the last `generate` restored instead of decoding.
    private(set) var reusedPrefixTokens = 0

    /// Assistant-turn prefill that turns thinking off: the empty block is how the Qwen3 and Qwen3.5
    /// templates render `enable_thinking=false`, and llama.cpp's template call has no switch for it.
    private static let emptyThinkBlock = "<think>\n\n</think>\n\n"

    /// Stands in for the user's text while locating where the template puts it.
    private static let userMarker = "<<OSW_USER_TEXT>>"

    // llama_backend_init() must be called once per process before loading any model.
    // Use a static token so repeated LlamaContext creations don't re-init the backend.
    private static let backendInit: Void = {
        llama_backend_init()
        return ()
    }()

    // MARK: - Initialization

    /// Loads a GGUF model from disk and creates an inference context.
    /// GPU offload is enabled (all layers) so Metal is used, matching the whisper path.
    init?(modelPath: String, contextLength: UInt32 = 4096, gpuLayers: Int32 = 999) {
        _ = LlamaContext.backendInit

        // --- Load the model ---
        var modelParams = llama_model_default_params()
        // 999 ≈ "offload everything"; llama clamps to the model's actual layer count.
        modelParams.n_gpu_layers = gpuLayers
        modelParams.use_mmap = true

        let loadedModel = modelPath.withCString { cPath in
            llama_model_load_from_file(cPath, modelParams)
        }
        guard let loadedModel else {
            print("LlamaContext: failed to load model at \(modelPath)")
            return nil
        }
        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)
        self.supportsThinking = Self.templateSupportsThinking(
            llama_model_chat_template(loadedModel, nil).map { String(cString: $0) })

        // --- Create the context ---
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextLength
        ctxParams.n_batch = contextLength
        // One cache shared by both sequences: the prefix copy tags the same cells instead of
        // duplicating them, and `n_ctx` is not split per sequence.
        ctxParams.n_seq_max = 2
        ctxParams.kv_unified = true
        let cpuCount = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        ctxParams.n_threads = cpuCount
        ctxParams.n_threads_batch = cpuCount

        guard let createdCtx = llama_init_from_model(loadedModel, ctxParams) else {
            print("LlamaContext: failed to create context")
            llama_model_free(loadedModel)
            self.model = nil
            return nil
        }
        self.ctx = createdCtx

        // --- Build a greedy (temperature-0) sampler chain ---
        // For deterministic cleanup we want greedy decoding.
        let samplerParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerParams) else {
            print("LlamaContext: failed to init sampler chain")
            llama_free(createdCtx)
            llama_model_free(loadedModel)
            self.ctx = nil
            self.model = nil
            return nil
        }
        // Greedy = argmax. Deterministic, no temperature.
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        self.sampler = chain
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        // We intentionally do NOT call llama_backend_free() here: ggml/Metal global
        // state is shared process-wide (and also used by whisper.cpp via the same
        // ggml). Freeing it on a single context teardown would be unsafe.
    }

    // MARK: - Chat prompt formatting

    /// Formats a system+user pair into the model's chat template. Falls back to a
    /// minimal ChatML-ish template if the model carries no built-in template.
    private func formatChatPrompt(system: String, user: String) -> String {
        guard let model else { return fallbackTemplate(system: system, user: user) }

        // Keep the C strings alive for the duration of the llama_chat_apply_template call.
        return system.withCString { sysC -> String in
            user.withCString { usrC -> String in
                let messages = [
                    llama_chat_message(role: strdup("system"), content: sysC),
                    llama_chat_message(role: strdup("user"), content: usrC),
                ]
                defer {
                    free(UnsafeMutableRawPointer(mutating: messages[0].role))
                    free(UnsafeMutableRawPointer(mutating: messages[1].role))
                }

                // Use the model's own template (tmpl == nil -> model default).
                let tmpl: UnsafePointer<CChar>? = llama_model_chat_template(model, nil)

                // First call to size the buffer, then realloc if needed.
                var bufSize = Int32((system.utf8.count + user.utf8.count) * 2 + 256)
                var buffer = [CChar](repeating: 0, count: Int(bufSize))
                var written = messages.withUnsafeBufferPointer { msgPtr in
                    llama_chat_apply_template(tmpl, msgPtr.baseAddress, msgPtr.count,
                                              true, &buffer, bufSize)
                }
                if written < 0 {
                    return fallbackTemplate(system: system, user: user)
                }
                if written > bufSize {
                    bufSize = written + 1
                    buffer = [CChar](repeating: 0, count: Int(bufSize))
                    written = messages.withUnsafeBufferPointer { msgPtr in
                        llama_chat_apply_template(tmpl, msgPtr.baseAddress, msgPtr.count,
                                                  true, &buffer, bufSize)
                    }
                    if written < 0 {
                        return fallbackTemplate(system: system, user: user)
                    }
                }
                let count = Int(min(written, bufSize))
                return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            }
        }
    }

    /// Minimal ChatML-style fallback (Qwen2.5 uses ChatML) if no template is available.
    private func fallbackTemplate(system: String, user: String) -> String {
        return """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant

        """
    }

    // MARK: - Tokenization helpers

    private func tokenize(_ text: String, addSpecial: Bool) -> [LlamaToken] {
        guard let vocab else { return [] }
        let utf8Count = Int32(text.utf8.count)
        // Upper bound: one token per byte + a couple for specials.
        let maxTokens = utf8Count + 8
        var tokens = [LlamaToken](repeating: 0, count: Int(maxTokens))

        let n = text.withCString { cText -> Int32 in
            llama_tokenize(vocab, cText, utf8Count, &tokens, maxTokens,
                           addSpecial, /* parse_special */ true)
        }
        if n < 0 {
            // Negative return = required count; resize and retry.
            let needed = -n
            tokens = [LlamaToken](repeating: 0, count: Int(needed))
            let n2 = text.withCString { cText -> Int32 in
                llama_tokenize(vocab, cText, utf8Count, &tokens, needed,
                               addSpecial, true)
            }
            guard n2 > 0 else { return [] }
            return Array(tokens.prefix(Int(n2)))
        }
        return Array(tokens.prefix(Int(n)))
    }

    /// Raw UTF-8 bytes of a token's piece. Deliberately NOT decoded per token: a BPE token can end
    /// mid-character (accented text, CJK, emoji), so decoding each piece on its own turns the split
    /// character into U+FFFD. Callers accumulate the bytes and decode the whole run once.
    private func pieceBytes(for token: LlamaToken) -> [UInt8] {
        guard let vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 128)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, /* special */ false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            guard n2 > 0 else { return [] }
            return buf.prefix(Int(n2)).map { UInt8(bitPattern: $0) }
        }
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    private func isEndOfGeneration(_ token: LlamaToken) -> Bool {
        guard let vocab else { return true }
        return llama_vocab_is_eog(vocab, token)
    }

    // MARK: - Decoding

    private func decode(_ tokens: [LlamaToken]) -> Bool {
        guard let ctx else { return false }
        var tokens = tokens
        return tokens.withUnsafeMutableBufferPointer { buf -> Bool in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            return llama_decode(ctx, batch) == 0
        }
    }

    /// Tokens of everything the template renders before the user's text. The system prompt is the
    /// part that repeats between cleanups, so this is what is worth keeping decoded.
    private func systemPrefixTokens(system: String) -> [LlamaToken] {
        let rendered = formatChatPrompt(system: system, user: Self.userMarker)
        guard let marker = rendered.range(of: Self.userMarker, options: .backwards) else { return [] }
        return tokenize(String(rendered[..<marker.lowerBound]), addSpecial: true)
    }

    /// Replaces sequence 0 with a copy of sequence 1. Checks the resulting position because
    /// `llama_batch_get_one` continues from wherever the cache says the sequence ends.
    private func copyPrefixSequence(tokenCount: Int) -> Bool {
        guard let ctx else { return false }
        let mem = llama_get_memory(ctx)
        guard llama_memory_seq_rm(mem, Self.generationSequence, -1, -1) else { return false }
        llama_memory_seq_cp(mem, Self.prefixSequence, Self.generationSequence, -1, -1)
        return llama_memory_seq_pos_max(mem, Self.generationSequence) == llama_pos(tokenCount - 1)
    }

    /// Decodes `promptTokens` into an emptied sequence 0. Every call is an independent completion,
    /// and this is not optional hygiene: `llama_batch_get_one` carries no explicit positions, so
    /// llama continues from wherever the last decode stopped. Without emptying it, dictation N+1
    /// decodes appended to N (earlier dictations leak into this one's context) and once the
    /// accumulated tokens pass `n_ctx`, `llama_decode` fails outright and every later cleanup
    /// returns "" (a silent no-op until the app restarts).
    ///
    /// When the tokens start with the tokens of the system prompt, that prefix is copied from
    /// sequence 1 and only the rest is decoded. A changed system prompt or a failed copy clears the
    /// cache, decodes the prefix again and keeps it in sequence 1. A prompt that does not start
    /// with the prefix (a truncated prompt) is decoded in full after clearing sequence 1 as well:
    /// its cells are not shared with sequence 0 then, so they would eat into the `n_ctx` that the
    /// truncation assumes to be free.
    private func decodePrompt(_ promptTokens: [LlamaToken], system: String) -> Bool {
        reusedPrefixTokens = 0
        guard let ctx else { return false }
        let mem = llama_get_memory(ctx)
        let prefix = systemPrefixTokens(system: system)
        // At least one token must stay behind: only a decode leaves logits to sample from.
        guard !prefix.isEmpty, prefix.count < promptTokens.count,
              promptTokens.starts(with: prefix) else {
            llama_memory_clear(mem, true)
            keptPrefix = nil
            return decode(promptTokens)
        }

        if keptPrefix == prefix, copyPrefixSequence(tokenCount: prefix.count) {
            reusedPrefixTokens = prefix.count
        } else {
            // A failed copy can leave a partial sequence behind.
            llama_memory_clear(mem, true)
            keptPrefix = nil
            guard decode(prefix) else { return false }
            llama_memory_seq_cp(mem, Self.generationSequence, Self.prefixSequence, -1, -1)
            keptPrefix = prefix
        }
        return decode(Array(promptTokens.dropFirst(prefix.count)))
    }

    // MARK: - Thinking

    /// Qwen3-style templates switch reasoning with `enable_thinking`.
    static func templateSupportsThinking(_ template: String?) -> Bool {
        template?.contains("enable_thinking") ?? false
    }

    // MARK: - Generation

    /// Runs a single-shot chat completion: formats the prompt, decodes the prompt
    /// tokens, then greedily samples up to `maxTokens` tokens, stopping at EOG.
    ///
    /// A model with a thinking mode answers straight away: a cleanup gains little from reasoning
    /// and would wait many times longer.
    ///
    /// Returns "" when the budget runs out before the model finishes: a cut-off reply is never
    /// better than the text it was meant to improve, and callers treat "" as "use the original".
    func generate(system: String, user: String, maxTokens: Int = 512) -> String {
        guard let ctx, let sampler else { return "" }

        // Every call is an independent completion: `decodePrompt` empties the KV cache sequence, and
        // the sampler's accepted-token history belongs to the previous generation.
        llama_sampler_reset(sampler)

        var prompt = formatChatPrompt(system: system, user: user)
        if supportsThinking { prompt += Self.emptyThinkBlock }
        var promptTokens = tokenize(prompt, addSpecial: true)
        guard !promptTokens.isEmpty else { return "" }

        let nCtx = Int(llama_n_ctx(ctx))
        if promptTokens.count >= nCtx {
            // Truncate the prompt if it doesn't fit; leave room for the response.
            promptTokens = Array(promptTokens.suffix(nCtx - 1))
        }

        var outputBytes: [UInt8] = []
        guard decodePrompt(promptTokens, system: system) else { return "" }

        var generated = 0
        var finished = false
        let budget = min(maxTokens, max(0, nCtx - promptTokens.count))
        while generated < budget {
            // Sample the next token from the logits of the last decoded position.
            let nextToken = llama_sampler_sample(sampler, ctx, -1)

            if isEndOfGeneration(nextToken) {
                finished = true
                break
            }

            llama_sampler_accept(sampler, nextToken)
            outputBytes.append(contentsOf: pieceBytes(for: nextToken))

            // Feed the sampled token back in for the next step.
            if !decode([nextToken]) { break }

            generated += 1
        }

        guard finished else { return "" }

        // One decode over the whole byte run, so multi-byte characters that straddled two tokens
        // survive intact.
        return String(decoding: outputBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
