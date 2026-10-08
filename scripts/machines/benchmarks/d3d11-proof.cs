using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public class D3DProof {
 [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr a,uint type,IntPtr module,uint flags,IntPtr levels,uint count,uint sdk,out IntPtr device,out uint level,out IntPtr context);
 [StructLayout(LayoutKind.Sequential)] struct Texture {public uint width,height,mips,array,format,samples,quality,usage,bind,cpu,misc;}
 [StructLayout(LayoutKind.Sequential)] struct Mapped {public IntPtr data;public uint row,depth;}
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateTexture(IntPtr self,ref Texture desc,IntPtr initial,out IntPtr result);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateView(IntPtr self,IntPtr texture,IntPtr desc,out IntPtr result);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Clear(IntPtr self,IntPtr view,[MarshalAs(UnmanagedType.LPArray,SizeConst=4)] float[] color);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Copy(IntPtr self,IntPtr destination,IntPtr source);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int Map(IntPtr self,IntPtr texture,uint sub,uint type,uint flags,out Mapped mapped);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Unmap(IntPtr self,IntPtr texture,uint sub);
 static T Method<T>(IntPtr obj,int slot) where T:class {return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj),slot*IntPtr.Size),typeof(T)) as T;}
 static void Check(int hr){if(hr<0)Marshal.ThrowExceptionForHR(hr);}
 static void Run(uint type,int run){
  IntPtr device=IntPtr.Zero,context=IntPtr.Zero,target=IntPtr.Zero,stage=IntPtr.Zero,view=IntPtr.Zero;
  try {uint level;Check(D3D11CreateDevice(IntPtr.Zero,type,IntPtr.Zero,0,IntPtr.Zero,0,7,out device,out level,out context));
   Texture desc=new Texture{width=800,height=600,mips=1,array=1,format=28,samples=1,bind=32};
   var create=Method<CreateTexture>(device,5);Check(create(device,ref desc,IntPtr.Zero,out target));
   Check(Method<CreateView>(device,9)(device,target,IntPtr.Zero,out view));
   desc.usage=3;desc.bind=0;desc.cpu=0x20000;Check(create(device,ref desc,IntPtr.Zero,out stage));
   var clear=Method<Clear>(context,50);var copy=Method<Copy>(context,47);var map=Method<Map>(context,14);var unmap=Method<Unmap>(context,15);
   float[] color={0.25f,0.5f,0.75f,1.0f};
   Action frame=()=>{clear(context,view,color);copy(context,stage,target);Mapped mapped;Check(map(context,stage,0,1,0,out mapped));
    int[] expected={64,128,191,255};for(int i=0;i<4;i++)if(Math.Abs(Marshal.ReadByte(mapped.data,i)-expected[i])>1)throw new Exception("pixel mismatch");unmap(context,stage,0);};
   for(int i=0;i<20;i++)frame();var timer=Stopwatch.StartNew();int frames=0;while(timer.Elapsed.TotalSeconds<3){frame();frames++;}timer.Stop();
   Console.WriteLine("type={0} run={1} feature=0x{2:X} frames={3} seconds={4:F3} fps={5:F2} pixels=PASS",type,run,level,frames,timer.Elapsed.TotalSeconds,frames/timer.Elapsed.TotalSeconds);
  }catch(Exception e){Console.WriteLine("type={0} run={1} FAIL {2} HRESULT=0x{3:X8}",type,run,e.Message,e.HResult);}
  finally{foreach(var p in new[]{view,stage,target,context,device})if(p!=IntPtr.Zero)Marshal.Release(p);}
 }
 public static void Main(){Console.WriteLine("800x600 RGBA clear + synchronous staging readback, verified pixels per frame; not a gaming benchmark");for(int i=1;i<=3;i++){Run(1,i);Run(5,i);}}
}
