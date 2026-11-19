import 'package:flutter/material.dart';
import '../../theme.dart';
import 'dashboard_models.dart';
class ControllerDetailCard extends StatelessWidget {
  const ControllerDetailCard({super.key,required this.controller,required this.title});
  final ControllerSnapshot? controller;
  final String title;
  @override Widget build(BuildContext context){
    final c=controller;
    final items=<({String title,String key,String suffix})>[
      (title:'Temperature',key:'temperature',suffix:' °C'),(title:'Humidity',key:'humidity',suffix:' %'),
      (title:'MQ-2 raw',key:'smoke_raw',suffix:''),(title:'Smoke status',key:'smoke_status',suffix:''),
      (title:'Flame',key:'flame_detected',suffix:''),(title:'Door',key:'door_status',suffix:''),
      (title:'Window',key:'window_status',suffix:''),(title:'Motion',key:'motion_detected',suffix:''),
      (title:'Active buzzer',key:'siren_active',suffix:''),(title:'Armed',key:'system_armed',suffix:''),
      (title:'System mode',key:'system_mode',suffix:''),(title:'Alert',key:'alert_status',suffix:''),
    ];
    return Container(padding:const EdgeInsets.all(16),decoration:GlassStyle.card(light:!AppTheme.isDark(context),border:AppColors.orange.withValues(alpha:.28)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[const Icon(Icons.memory_outlined,color:AppColors.orange),const SizedBox(width:8),Expanded(child:Text(title,style:TextStyle(fontWeight:FontWeight.w800,color:AppTheme.textPrimary(context)))),Text(c?.connectionText??'NO DATA',style:TextStyle(fontSize:10,fontWeight:FontWeight.w800,color:c?.connected==true?AppColors.green:AppColors.amber))]),
      const SizedBox(height:7),Text('Sensor: ${c?.sampledAt?.toLocal().toString()??'Not reported'}  •  Heartbeat: ${c?.heartbeatAt?.toLocal().toString()??'Not reported'}',style:TextStyle(color:AppTheme.textSecondary(context),fontSize:10)),
      const SizedBox(height:12),LayoutBuilder(builder:(context,limits){final n=limits.maxWidth>600?3:limits.maxWidth>340?2:1;final width=(limits.maxWidth-(n-1)*10)/n;
        return Wrap(spacing:10,runSpacing:12,children:items.map((e)=>SizedBox(width:width,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(e.title,style:TextStyle(fontSize:10,color:AppTheme.textSecondary(context))),const SizedBox(height:3),Text(c?.display(e.key,suffix:e.suffix)??'NO DATA',style:TextStyle(fontWeight:FontWeight.w700,fontSize:12,color:AppTheme.textPrimary(context)))]))).toList());
      }),
    ]));
  }
}
