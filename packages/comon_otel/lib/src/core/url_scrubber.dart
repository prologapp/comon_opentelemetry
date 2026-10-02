import 'semantic_attributes.dart';

/// Matches `scheme://authority` plus everything after it up to the next
/// whitespace, quote, `<`, `>` or backtick — including a JSON-escaped quote
/// (`\"`). Over-consuming trailing text is safe (it is dropped);
/// under-consuming would leak path or query.
///
/// No resto (grupo 3) a barra invertida só entra em par com o caractere
/// seguinte (`\/`, `\\`, `\u…`), e nunca quando esse caractere encerraria a
/// URL. Assim um `\"` fecha a URL e sobrevive ao scrub — corpo de log e
/// atributo com JSON serializado continuam JSON válido —, um `\\` antes da
/// aspa de fechamento é consumido inteiro (a aspa não vira escapada) e a
/// barra escapada por encoders que escapam `/` continua descartada com o
/// path. Cada passo do grupo 3 é decidido pelo primeiro caractere, então o
/// casamento segue linear.
///
/// O esquema é limitado a 32 caracteres: sem limite, uma sequência longa de
/// `[A-Za-z0-9+.-]` que não termina em `://` faz cada posição inicial varrer
/// o resto da sequência (O(n²); 64 KB levavam ~2,6 s, e isto roda antes do
/// corte de 4 KiB). Com o limite, um esquema maior que 32 caracteres casa só
/// nos últimos 32; path e query continuam descartados.
final RegExp _urlPattern = RegExp(
  r'''([A-Za-z][A-Za-z0-9+.\-]{0,31})://([^\s/?#"'<>`\\]*)'''
  r'''((?:[^\s"'<>`\\]|\\[^\s"'<>`])*)''',
);

/// Replaces every URL in [text] with its scheme and host only.
///
/// `https://bucket.s3.amazonaws.com/a/b?X-Amz-Signature=…` becomes
/// `https://bucket.s3.amazonaws.com/…`: path, query and fragment are dropped
/// (they carry PII such as a CPF in the path and pre-signed signatures in the
/// query), userinfo is dropped, and the port is kept. A bare origin is left
/// as is. Strings without `://` (e.g. `package:` and `dart:` stack frames)
/// are returned unchanged. The function is idempotent.
///
/// Limite: só `://` literal abre uma URL. Texto em que o próprio separador
/// vem escapado (`https:\/\/h.com\/cpf`, de encoders que escapam `/` em
/// tudo) passa sem scrub; o `jsonEncode` do `dart:convert` não escapa `/`.
///
/// Error text (exception messages, stack traces, status descriptions,
/// diagnostics) must pass through this before it is recorded as telemetry.
String scrubUrls(String text) {
  if (!text.contains('://')) {
    return text;
  }

  return text.replaceAllMapped(_urlPattern, (match) {
    final scheme = match[1]!;
    final authority = match[2]!;
    final rest = match[3]!;
    final at = authority.lastIndexOf('@');
    final host = at < 0 ? authority : authority.substring(at + 1);
    return rest.isEmpty ? '$scheme://$host' : '$scheme://$host/…';
  });
}

/// Scrubs [value] with [scrubUrls] when [key] holds exception text
/// (`exception.message` or `exception.stacktrace`); any other attribute is
/// returned unchanged.
///
/// Applied at the SDK sinks (span attributes, span event attributes, log
/// records) so every path that records an error — `recordException`,
/// `OtelLogger.error`, log bridges, helpers — is covered at once.
Object scrubExceptionAttribute(String key, Object value) {
  if (value is String &&
      (key == SemanticAttributes.exceptionMessage ||
          key == SemanticAttributes.exceptionStacktrace)) {
    return scrubUrls(value);
  }
  return value;
}
