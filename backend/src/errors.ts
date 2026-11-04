/** 业务错误：code 给客户端判断，message 是可以直接给用户看的中文。 */
export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly details?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export const badRequest = (code: string, msg: string, details?: Record<string, unknown>) => new AppError(400, code, msg, details);
export const unauthorized = (msg = '请先登录') => new AppError(401, 'unauthorized', msg);
export const forbidden = (code: string, msg: string) => new AppError(403, code, msg);
export const notFound = (code = 'not_found', msg = '找不到') => new AppError(404, code, msg);
export const conflict = (code: string, msg: string, details?: Record<string, unknown>) => new AppError(409, code, msg, details);
export const tooMany = (code: string, msg: string, details?: Record<string, unknown>) => new AppError(429, code, msg, details);
