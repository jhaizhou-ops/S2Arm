using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Account.Acc.AsyncContext;
using System.Threading;
using System.Threading.Tasks;

namespace Ryujinx.HLE.HOS.Services.Account.Acc.AccountService
{
    class ManagerServer
    {
#pragma warning disable IDE0052 // Remove unread private member
        private readonly UserId _userId;
#pragma warning restore IDE0052

        public ManagerServer(UserId userId)
        {
            _userId = userId;
        }

        public ResultCode CheckAvailability(ServiceCtx context)
        {
            // 真机码未查到，按离线语义假设：没有绑定网络账号。
            return ResultCode.NetworkServiceAccountRegistrationRequired;
        }

        public ResultCode GetAccountId(ServiceCtx context)
        {
            // 真机码未查到，按离线语义假设：没有绑定网络账号，不写虚构账号 ID。
            return ResultCode.NetworkServiceAccountRegistrationRequired;
        }

        public ResultCode EnsureIdTokenCacheAsync(ServiceCtx context, out IAsyncContext asyncContext)
        {
            KEvent asyncEvent = new(context.Device.System.KernelContext);
            // 真机码未查到，按离线语义假设：同步返回对象，异步 GetResult 回错。
            AsyncExecution asyncExecution = new(asyncEvent, ResultCode.NetworkServiceAccountRegistrationRequired);

            asyncExecution.Initialize(1000, EnsureIdTokenCacheAsyncImpl);

            asyncContext = new IAsyncContext(asyncExecution);

            // return ResultCode.NullObject if the IAsyncContext pointer is null. Doesn't occur in our case.

            return ResultCode.Success;
        }

        private async Task EnsureIdTokenCacheAsyncImpl(CancellationToken token)
        {
            // NOTE: This open the file at "su/baas/USERID_IN_UUID_STRING.dat" (where USERID_IN_UUID_STRING is formatted as "%08x-%04x-%04x-%02x%02x-%08x%04x")
            //       in the "account:/" savedata.
            //       Then its read data, use dauth API with this data to get the Token Id and probably store the dauth response
            //       in "su/cache/USERID_IN_UUID_STRING.dat" (where USERID_IN_UUID_STRING is formatted as "%08x-%04x-%04x-%02x%02x-%08x%04x") in the "account:/" savedata.
            //       The offline result is carried by AsyncExecution.

            Logger.Stub?.PrintStub(LogClass.ServiceAcc);

            // TODO: Use a real function instead, with the CancellationToken.
            await Task.CompletedTask;
        }

        public ResultCode LoadIdTokenCache(ServiceCtx context)
        {
            // 真机码未查到，按离线语义假设：命令 3 / 4 均不签发伪造的令牌。
            return ResultCode.NetworkServiceAccountRegistrationRequired;
        }

        public ResultCode GetNintendoAccountUserResourceCacheForApplication(ServiceCtx context)
        {
            // 真机码未查到，按离线语义假设：不返回虚构账号与空资料。
            return ResultCode.NetworkServiceAccountRegistrationRequired;
        }

        public ResultCode StoreOpenContext(ServiceCtx context)
        {
            context.Device.System.AccountManager.StoreOpenedUsers();

            return ResultCode.Success;
        }

        public ResultCode LoadNetworkServiceLicenseKindAsync(ServiceCtx context, out IAsyncNetworkServiceLicenseKindContext asyncContext)
        {
            KEvent asyncEvent = new(context.Device.System.KernelContext);
            // 真机码未查到，按离线语义假设：同步返回对象，异步 GetResult 回错。
            AsyncExecution asyncExecution = new(asyncEvent, ResultCode.NetworkServiceAccountRegistrationRequired);

            Logger.Stub?.PrintStub(LogClass.ServiceAcc);

            // NOTE: This is an extension of the data retrieved from the id token cache.
            asyncExecution.Initialize(1000, EnsureIdTokenCacheAsyncImpl);

            asyncContext = new IAsyncNetworkServiceLicenseKindContext(asyncExecution, null);

            // return ResultCode.NullObject if the IAsyncNetworkServiceLicenseKindContext pointer is null. Doesn't occur in our case.

            return ResultCode.Success;
        }
    }
}
